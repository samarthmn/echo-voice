import AVFoundation
import XCTest
@testable import EchoCapture

final class MicrophoneGateTests: XCTestCase {
    func testMuteAlsoClosesFutureQueuesAndUnmuteRequiresAFreshEpoch() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let gate = MicrophoneAdmissionGate()
        let opening = try RealtimeBufferQueue(format: format)
        gate.close(at: 100)
        gate.register(opening)
        XCTAssertEqual(opening.muteHostTime, 100)
        gate.open()
        let next = try RealtimeBufferQueue(format: format)
        gate.register(next)
        XCTAssertEqual(next.muteHostTime, 0)
        XCTAssertEqual(opening.muteHostTime, 100, "Unmute must not reopen old queues containing pre-gap buffers")
        gate.close(at: 200)
        XCTAssertEqual(opening.muteHostTime, 100, "A later mute must not move the old epoch's trimming boundary")
        XCTAssertEqual(next.muteHostTime, 200)
    }
    func testAddingMicrophoneLateDoesNotStallWorkerOrLoseRemoteTrack() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ECHO_TEST_ROOT"] ?? FileManager.default.currentDirectoryPath + "/tmp/tests")
            .appendingPathComponent("late-microphone-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let remote = try RealtimeBufferQueue(format: format)
        let microphone = try RealtimeBufferQueue(format: format)
        let origin = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        let failure = XCTestExpectation(description: "healthy remote capture must not fail")
        failure.isInverted = true
        let worker = try RecordingWorker(
            configuration: CaptureConfiguration(meetingID: "fixture", meetingDirectory: root,
                                                application: nil, microphone: nil, allowSingleSource: true),
            timeline: CaptureTimeline(originSeconds: origin, initialOffset: 0),
            sources: [(.remote, remote)], onEvent: { _ in }, onFailure: { _, _ in failure.fulfill() }
        )
        worker.start()
        try await Task.sleep(for: .seconds(3.2))
        try worker.addTrack(.microphone, ring: microphone)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        buffer.frameLength = 480
        remote.push(buffer.audioBufferList, frames: 480, hostTime: mach_absolute_time())
        try await Task.sleep(for: .milliseconds(80))
        await worker.finish()
        await fulfillment(of: [failure], timeout: 0.1)
        let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("audio"), includingPropertiesForKeys: nil)
        XCTAssertTrue(files.contains { $0.lastPathComponent.hasPrefix("remote-") && $0.pathExtension == "caf" })
    }

    func testQueuedBoundaryBufferIsTrimmedWhileOtherTrackContinues() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ECHO_TEST_ROOT"] ?? FileManager.default.currentDirectoryPath + "/tmp/tests")
            .appendingPathComponent("microphone-boundary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let microphone = try RealtimeBufferQueue(format: format)
        let remote = try RealtimeBufferQueue(format: format)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        buffer.frameLength = 480
        for index in 0..<480 { buffer.floatChannelData![0][index] = 0.5 }
        let origin = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        let startHost = AVAudioTime.hostTime(forSeconds: origin)
        microphone.push(buffer.audioBufferList, frames: 480, hostTime: startHost)
        remote.push(buffer.audioBufferList, frames: 480, hostTime: startHost)
        microphone.mute(atHostTime: AVAudioTime.hostTime(forSeconds: origin + 0.005))
        let worker = try RecordingWorker(
            configuration: CaptureConfiguration(meetingID: "fixture", meetingDirectory: root,
                                                application: nil, microphone: nil, allowSingleSource: true),
            timeline: CaptureTimeline(originSeconds: origin, initialOffset: 0),
            sources: [(.microphone, microphone), (.remote, remote)],
            onEvent: { _ in }, onFailure: { reason, _ in XCTFail(reason) }
        )
        worker.start()
        await worker.finish()
        let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("audio"), includingPropertiesForKeys: nil)
        let microphoneURL = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix("microphone-") && $0.pathExtension == "caf" })
        let remoteURL = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix("remote-") && $0.pathExtension == "caf" })
        XCTAssertLessThanOrEqual(abs(try AVAudioFile(forReading: microphoneURL).length - 240), 1)
        XCTAssertEqual(try AVAudioFile(forReading: remoteURL).length, 480)
    }

    func testGateDropsNewBuffersWithoutReportingOverflowAndCanReopen() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let queue = try RealtimeBufferQueue(format: format)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        buffer.frameLength = 480
        queue.push(buffer.audioBufferList, frames: 480, hostTime: 100)
        queue.mute(atHostTime: 105)
        queue.push(buffer.audioBufferList, frames: 480, hostTime: 110)
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        XCTAssertEqual(queue.pop(into: output), 100)
        XCTAssertNil(queue.pop(into: output))
        XCTAssertEqual(queue.overflowCount, 0)
        queue.unmute()
        queue.push(buffer.audioBufferList, frames: 480, hostTime: 120)
        XCTAssertEqual(queue.pop(into: output), 120)
    }
}
