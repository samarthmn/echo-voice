import XCTest
@testable import EchoCapture

final class CaptureLogicTests: XCTestCase {
    func testAutomaticStartPreflightUsesActualFormats() throws {
        enum Marker: Error { case called }
        let formats = [CaptureAudioFormat(track: .microphone, sampleRate: 48_000, channels: 1)]
        let configuration = CaptureConfiguration(meetingID: "test", meetingDirectory: URL(fileURLWithPath: "/unused"), application: nil, microphone: nil, allowSingleSource: true, formatPreflight: {
            XCTAssertEqual($0, formats); throw Marker.called
        })
        XCTAssertThrowsError(try configuration.runFormatPreflight(formats)) { XCTAssertTrue($0 is Marker) }
    }
    func testTimelineUsesHostClockAndInitialOffset() {
        let clock = CaptureTimeline(originSeconds: 100, initialOffset: 30)
        XCTAssertEqual(clock.time(hostSeconds: 102.25), 32.25, accuracy: 0.00001)
    }
    func testClockDiscontinuityIsExplicitAndSmallDriftIsTolerated() {
        var tracker = TrackContinuity()
        XCTAssertFalse(tracker.observe(start: 1, frames: 480, sampleRate: 48000))
        XCTAssertFalse(tracker.observe(start: 1.0101, frames: 480, sampleRate: 48000))
        XCTAssertTrue(tracker.observe(start: 1.5, frames: 480, sampleRate: 48000))
    }
    func testFiveSecondChunkBoundaryHandlesPartialBuffers() {
        var plan = ChunkFramePlan(sampleRate: 48000)
        XCTAssertEqual(plan.take(available: 239999), 239999)
        XCTAssertFalse(plan.isFull)
        XCTAssertEqual(plan.take(available: 512), 1)
        XCTAssertTrue(plan.isFull)
        plan.reset()
        XCTAssertEqual(plan.take(available: 511), 511)
    }
    func testDedupIsScopedAndComparesPerceptualDistance() {
        var dedup = ScreenshotDeduplicator()
        XCTAssertTrue(dedup.shouldSave(hash: 0, scope: "meeting:window1"))
        XCTAssertFalse(dedup.shouldSave(hash: 3, scope: "meeting:window1"))
        XCTAssertTrue(dedup.shouldSave(hash: 0, scope: "meeting:window2"))
        XCTAssertTrue(dedup.shouldSave(hash: UInt64.max, scope: "meeting:window1"))
        dedup.reset()
        XCTAssertTrue(dedup.shouldSave(hash: UInt64.max, scope: "meeting:window1"))
    }
}

import AVFoundation
import CryptoKit
import EchoCore

final class AudioBufferAndChunkTests: XCTestCase {
    private struct SimulatedCrash: Error {}

    func testConcurrentRingPreservesExactFramesWithDelayedConsumer() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let queue = try RealtimeBufferQueue(format: format, capacity: 64)
        let producer = expectation(description: "producer")
        let consumer = expectation(description: "consumer")
        // 1,000 packets fit inside the two-second ring even if the consumer stalls.
        DispatchQueue.global().async {
            let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64)!
            input.frameLength = 64
            for packet in 0..<1000 {
                for frame in 0..<64 { input.floatChannelData![0][frame] = Float(packet * 64 + frame) }
                queue.push(input.audioBufferList, frames: 64, hostTime: UInt64(packet + 1))
            }
            producer.fulfill()
        }
        DispatchQueue.global().async {
            Thread.sleep(forTimeInterval: 0.01)
            let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64)!
            let deadline = Date().addingTimeInterval(3)
            var packet = 0
            while packet < 1000 && Date() < deadline {
                guard let host = queue.pop(into: output) else { Thread.sleep(forTimeInterval: 0.0001); continue }
                XCTAssertEqual(host, UInt64(packet + 1))
                XCTAssertEqual(output.frameLength, 64)
                for frame in 0..<64 { XCTAssertEqual(output.floatChannelData![0][frame], Float(packet * 64 + frame)) }
                packet += 1
            }
            XCTAssertEqual(packet, 1000); consumer.fulfill()
        }
        wait(for: [producer, consumer], timeout: 4)
        XCTAssertEqual(queue.overflowCount, 0); XCTAssertEqual(queue.invalidFrameCount, 0)
    }

    func testBoundedQueueCopiesAudioAndReportsOverflow() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let queue = try RealtimeBufferQueue(format: format, capacity: 4, depth: 2)
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)!
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)!
        input.frameLength = 4
        for i in 0..<4 { input.floatChannelData![0][i] = Float(i) / 4 }
        queue.push(input.audioBufferList, frames: 4, hostTime: 123)
        input.floatChannelData![0][0] = 99
        XCTAssertEqual(queue.pop(into: output), 123)
        XCTAssertEqual(output.floatChannelData![0][0], 0)
        XCTAssertEqual(output.floatChannelData![0][3], 0.75)
        XCTAssertNil(queue.pop(into: output))
        queue.push(input.audioBufferList, frames: 4, hostTime: 124)
        queue.push(input.audioBufferList, frames: 4, hostTime: 125)
        queue.push(input.audioBufferList, frames: 4, hostTime: 126)
        XCTAssertTrue(queue.hasDroppedAudio)
        XCTAssertEqual(queue.pop(into: output), 124)
        XCTAssertEqual(queue.pop(into: output), 125)
        XCTAssertNil(queue.pop(into: output))
    }
    func testChunkWriterFinalizesExactFiveSecondsAndIndependentTail() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ECHO_TEST_ROOT"] ?? FileManager.default.currentDirectoryPath + "/tmp/tests")
        let directory = root.appendingPathComponent("capture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let collector = ChunkCollector()
        let configuration = CaptureConfiguration(meetingID: "test", meetingDirectory: directory, application: nil, microphone: nil, allowSingleSource: true)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let writer = try AudioChunkWriter(track: .microphone, inputFormat: format, configuration: configuration) { if case .chunk(let chunk) = $0 { collector.chunks.append(chunk) } }
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
        buffer.frameLength = 48000
        for frame in 0..<48000 { buffer.floatChannelData![0][frame] = sin(Float(frame) * 0.01) * 0.2 }
        for second in 0..<6 { _ = try writer.append(buffer, at: Double(second) + 10, epoch: "epoch") }
        try writer.finish()
        XCTAssertEqual(collector.chunks.count, 2)
        XCTAssertEqual(collector.chunks.map(\.frameCount), [240000, 48000])
        XCTAssertEqual(collector.chunks.map(\.startTime), [10, 15])
        XCTAssertEqual(collector.chunks.map(\.duration), [5, 1])
        for chunk in collector.chunks {
            XCTAssertFalse(chunk.relativePath.hasPrefix("/"))
            XCTAssertFalse(chunk.relativePath.contains("partial"))
            let url = directory.appendingPathComponent(chunk.relativePath)
            let data = try Data(contentsOf: url)
            XCTAssertEqual(chunk.sha256, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
            XCTAssertEqual(try AVAudioFile(forReading: url).length, chunk.frameCount)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathExtension("chunk.json").path))
        }
    }

    func testCrashAfterSidecarBeforeAudioRenameIsRecoveredOnStoreStartup() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ECHO_TEST_ROOT"] ?? FileManager.default.currentDirectoryPath + "/tmp/tests")
        let directory = root.appendingPathComponent("capture-recovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = AppPaths(root: directory.appendingPathComponent("data", isDirectory: true))
        var store: MeetingStore? = try MeetingStore(paths: paths)
        try store?.createMeeting(Meeting(
            id: "test", title: "Recovery", startedAt: Date(), endedAt: nil, state: .recording,
            language: "en", sourceName: "Test", usesEchoCancellation: false, transcriptRevision: 0
        ))
        let configuration = CaptureConfiguration(
            meetingID: "test", meetingDirectory: paths.meetingDirectory("test"),
            application: nil, microphone: nil, allowSingleSource: true
        )
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let writer = try AudioChunkWriter(
            track: .microphone,
            inputFormat: format,
            configuration: configuration,
            publicationCheckpoint: { throw SimulatedCrash() },
            onEvent: { _ in XCTFail("Chunk must not emit before final audio rename") }
        )
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
        buffer.frameLength = 480
        for frame in 0..<480 { buffer.floatChannelData![0][frame] = 0.1 }
        _ = try writer.append(buffer, at: 12, epoch: "epoch-1")

        XCTAssertThrowsError(try writer.finish())
        let audioDirectory = paths.meetingDirectory("test").appendingPathComponent("audio", isDirectory: true)
        let interruptedFiles = try FileManager.default.contentsOfDirectory(at: audioDirectory, includingPropertiesForKeys: nil)
        XCTAssertEqual(interruptedFiles.filter { $0.lastPathComponent.hasSuffix(".partial.caf") }.count, 1)
        XCTAssertEqual(interruptedFiles.filter { $0.lastPathComponent.hasSuffix(".caf.chunk.json") }.count, 1)

        store = nil
        store = try MeetingStore(paths: paths)
        let recovered = try XCTUnwrap(store?.chunks(meetingID: "test").first)
        XCTAssertEqual(recovered.epochID, "epoch-1")
        XCTAssertEqual(recovered.startTime, 12, accuracy: 0.000_001)
        XCTAssertEqual(recovered.frameCount, 480)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.meetingDirectory("test").appendingPathComponent(recovered.relativePath).path))
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(at: audioDirectory, includingPropertiesForKeys: nil)).allSatisfy {
            !$0.lastPathComponent.contains("partial") && !$0.lastPathComponent.hasSuffix("chunk.json")
        })
    }
}
private final class ChunkCollector: @unchecked Sendable { var chunks: [CapturedChunk] = [] }

final class RecordingWorkerTests: XCTestCase {
    func testHostClockJumpInterruptsInsteadOfWritingFalseContinuity() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ECHO_TEST_ROOT"] ?? FileManager.default.currentDirectoryPath + "/tmp/tests")
        let directory = root.appendingPathComponent("capture-clock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let queue = try RealtimeBufferQueue(format: format)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
        buffer.frameLength = 480
        for index in 0..<480 { buffer.floatChannelData![0][index] = 0.1 }
        let origin = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        queue.push(buffer.audioBufferList, frames: 480, hostTime: AVAudioTime.hostTime(forSeconds: origin))
        queue.push(buffer.audioBufferList, frames: 480, hostTime: AVAudioTime.hostTime(forSeconds: origin + 0.5))
        let failed = expectation(description: "Capture interruption with timestamp")
        let worker = try RecordingWorker(configuration: CaptureConfiguration(meetingID: "clock", meetingDirectory: directory, application: nil, microphone: nil, allowSingleSource: true), timeline: CaptureTimeline(originSeconds: origin, initialOffset: 0), sources: [(.microphone, queue)], onEvent: { _ in }) { reason, time in
            XCTAssertTrue(reason.contains("host-clock discontinuity"))
            XCTAssertEqual(time ?? -1, 0.01, accuracy: 0.001)
            failed.fulfill()
        }
        worker.start()
        await fulfillment(of: [failed], timeout: 2)
        await worker.finish()
        let urls = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("audio"), includingPropertiesForKeys: nil)
        let audioURLs = urls.filter { $0.pathExtension == "caf" && !$0.lastPathComponent.contains("partial") }
        XCTAssertEqual(audioURLs.count, 1)
        XCTAssertEqual(try AVAudioFile(forReading: audioURLs[0]).length, 480)
    }
}

final class AudioSourceLivenessTests: XCTestCase {
    func testSelectedAppCanWaitForItsFirstAudioWithoutInterruptingMicrophone() {
        XCTAssertEqual(AudioSourceLiveness.evaluate(track: .remote, lastEnd: nil, now: 3600, startedAt: 0), .waitingForFirstAudio)
        XCTAssertEqual(AudioSourceLiveness.evaluate(track: .microphone, lastEnd: 3599.99, now: 3600, startedAt: 0), .active)
    }
    func testEstablishedMissingStreamAndUnresponsiveMicrophoneAreStillInterrupted() {
        XCTAssertEqual(AudioSourceLiveness.evaluate(track: .remote, lastEnd: 10, now: 14, startedAt: 0), .stalled)
        XCTAssertEqual(AudioSourceLiveness.evaluate(track: .microphone, lastEnd: nil, now: 4, startedAt: 0), .stalled)
    }
    func testRealSilenceBuffersKeepSourceActive() {
        // Liveness depends on buffer timestamps, never sample amplitude.
        XCTAssertEqual(AudioSourceLiveness.evaluate(track: .remote, lastEnd: 3599.99, now: 3600, startedAt: 0), .active)
    }
}

extension RecordingWorkerTests {
    func testStoppingWhileWaitingForFirstRemoteBufferClosesExplicitGap() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ECHO_TEST_ROOT"] ?? FileManager.default.currentDirectoryPath + "/tmp/tests")
        let directory = root.appendingPathComponent("capture-wait-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let queue = try RealtimeBufferQueue(format: format)
        let origin = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        let opened = expectation(description: "Waiting gap persisted")
        let closed = expectation(description: "Waiting gap closed on stop")
        let worker = try RecordingWorker(configuration: CaptureConfiguration(meetingID: "waiting", meetingDirectory: directory, application: nil, microphone: nil, allowSingleSource: true), timeline: CaptureTimeline(originSeconds: origin, initialOffset: 0), sources: [(.remote, queue)], onEvent: { event in
            if case .gap(let gap) = event {
                if let end = gap.endTime { XCTAssertGreaterThanOrEqual(end, gap.startTime); closed.fulfill() }
                else { opened.fulfill() }
            }
            if case .interrupted(let reason) = event { XCTFail(reason) }
        }, onFailure: { reason, _ in XCTFail(reason) })
        worker.start()
        await fulfillment(of: [opened], timeout: 2)
        await worker.finish()
        await fulfillment(of: [closed], timeout: 1)
        let files = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("audio"), includingPropertiesForKeys: nil)
        XCTAssertTrue(files.isEmpty, "No silent remote audio should be fabricated")
    }
}


extension AudioBufferAndChunkTests {
    func testStereoAndFourChannelRawCAFPreserveIndependentChannelSamples() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ECHO_TEST_ROOT"] ?? FileManager.default.currentDirectoryPath + "/tmp/tests")
        let directory = root.appendingPathComponent("raw-four-channel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for channelCount in [2, 4] {
        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(channelCount)))
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, interleaved: false, channelLayout: layout)
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        input.frameLength = 480
        let values: [Float] = [0.1, -0.2, 0.3, -0.4]
        for channel in 0..<channelCount { for frame in 0..<480 { input.floatChannelData![channel][frame] = values[channel] } }
        let collector = ChunkCollector()
        let writer = try AudioChunkWriter(track: .microphone, inputFormat: format, configuration: CaptureConfiguration(meetingID: "four", meetingDirectory: directory, application: nil, microphone: nil, allowSingleSource: true)) { event in
            if case .chunk(let chunk) = event { collector.chunks.append(chunk) }
        }
        _ = try writer.append(input, at: 7, epoch: "epoch")
        try writer.finish()
        let chunk = try XCTUnwrap(collector.chunks.first)
        XCTAssertEqual(chunk.frameCount, 480)
        let file = try AVAudioFile(forReading: directory.appendingPathComponent(chunk.relativePath), commonFormat: .pcmFormatFloat32, interleaved: false)
        XCTAssertEqual(file.processingFormat.channelCount, AVAudioChannelCount(channelCount))
        XCTAssertEqual(file.processingFormat.sampleRate, 48000)
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 480))
        try file.read(into: output)
        for channel in 0..<channelCount { XCTAssertEqual(output.floatChannelData![channel][240], values[channel], accuracy: 0.00001) }
        }
    }
    func testRingCopiesAllFourChannelsInPlanarAndInterleavedFormats() throws {
        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 4))
        for interleaved in [false, true] {
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, interleaved: interleaved, channelLayout: layout)
            let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8))
            let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8))
            input.frameLength = 8
            let buffers = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
            for (index, buffer) in buffers.enumerated() {
                let floats = try XCTUnwrap(buffer.mData).assumingMemoryBound(to: Float.self)
                for sample in 0..<Int(buffer.mDataByteSize) / MemoryLayout<Float>.size { floats[sample] = Float(index * 100 + sample) / 1000 }
            }
            let queue = try RealtimeBufferQueue(format: format, capacity: 8, depth: 2)
            queue.push(input.audioBufferList, frames: 8, hostTime: 123)
            XCTAssertEqual(queue.pop(into: output), 123)
            XCTAssertEqual(output.frameLength, 8)
            let copied = UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)
            XCTAssertEqual(copied.count, buffers.count)
            for index in buffers.indices {
                XCTAssertEqual(copied[index].mNumberChannels, buffers[index].mNumberChannels)
                let expected = Data(bytes: try XCTUnwrap(buffers[index].mData), count: Int(buffers[index].mDataByteSize))
                let actual = Data(bytes: try XCTUnwrap(copied[index].mData), count: Int(copied[index].mDataByteSize))
                XCTAssertEqual(actual, expected)
            }
        }
    }
}
