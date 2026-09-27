import XCTest
import AVFoundation
import CryptoKit
import EchoCore
import EchoIntelligence
@testable import EchoRuntime

final class AudioWindowAssemblerTests: XCTestCase {
    func testHostTimelinePlacementPreservesGapInsteadOfClosingIt() throws {
        let fixture = try AudioFixture()
        defer { fixture.remove() }
        let first = try fixture.chunk(id: "first", start: 0, duration: 1, value: 0.25)
        let second = try fixture.chunk(id: "second", start: 2, duration: 1, value: 0.5)
        let assembled = try AudioWindowAssembler(paths: fixture.paths).assemble(meetingID: "test", chunks: [first, second], start: 0, duration: 3, relativePath: "derived/window.wav")
        XCTAssertEqual(assembled.frameCount, 48000)
        XCTAssertFalse(assembled.isFullyCovered)
        let file = try AVAudioFile(forReading: assembled.url)
        let samples = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: samples)
        XCTAssertEqual(samples.floatChannelData![0][8000], 0.25, accuracy: 0.001)
        XCTAssertEqual(samples.floatChannelData![0][24000], 0, accuracy: 0.001)
        XCTAssertEqual(samples.floatChannelData![0][40000], 0.5, accuracy: 0.001)
    }
    func testDriftUsesNextHostTimestampWithoutCreatingTinyGap() throws {
        let fixture = try AudioFixture()
        defer { fixture.remove() }
        let first = try fixture.chunk(id: "first", start: 0, duration: 1, value: 0.25)
        let second = try fixture.chunk(id: "second", start: 1.002, duration: 1, value: 0.5)
        let assembled = try AudioWindowAssembler(paths: fixture.paths).assemble(meetingID: "test", chunks: [first, second], start: 0, duration: 2, relativePath: "derived/drift.wav")
        XCTAssertTrue(assembled.isFullyCovered)
        XCTAssertEqual(assembled.frameCount, 32000)
    }
    func testChangedCanonicalAudioFailsIntegrityValidation() throws {
        let fixture = try AudioFixture()
        defer { fixture.remove() }
        var chunk = try fixture.chunk(id: "changed", start: 0, duration: 1, value: 0.25)
        chunk.sha256 = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try AudioWindowAssembler(paths: fixture.paths).assemble(meetingID: "test", chunks: [chunk], start: 0, duration: 1, relativePath: "derived/changed.wav"))
    }
    func testRightOnlySpeechSurvivesMonoAssemblyWithDefinedHeadroom() throws {
        let fixture = try AudioFixture()
        defer { fixture.remove() }
        let chunk = try fixture.channelChunk(id: "right", values: [0, 1])
        let result = try AudioWindowAssembler(paths: fixture.paths).assemble(meetingID: "test", chunks: [chunk], start: 0, duration: 1, relativePath: "derived/right.wav")
        XCTAssertEqual(try fixture.sample(result.url), 0.5, accuracy: 0.001)
    }
    func testMultichannelMixIncludesEveryChannelAndDoesNotClip() throws {
        let fixture = try AudioFixture()
        defer { fixture.remove() }
        for (id, values, expected) in [("four", [Float(0), 0, 0, 1], Float(0.25)), ("loud", [Float(1), 1, 1, 1], Float(1)), ("opposite", [Float(1), -1, 0.5, 0.5], Float(0.25))] {
            let chunk = try fixture.channelChunk(id: id, values: values)
            let result = try AudioWindowAssembler(paths: fixture.paths).assemble(meetingID: "test", chunks: [chunk], start: 0, duration: 1, relativePath: "derived/\(id).wav")
            XCTAssertEqual(try fixture.sample(result.url), expected, accuracy: 0.001)
        }
    }
    func testWindowLongerThanThirtySecondsIsRejected() throws {
        let fixture = try AudioFixture()
        defer { fixture.remove() }
        XCTAssertThrowsError(try AudioWindowAssembler(paths: fixture.paths).assemble(meetingID: "test", chunks: [], start: 0, duration: 31, relativePath: "derived/too-long.wav"))
    }
}
private struct AudioFixture {
    let paths: AppPaths
    init() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ECHO_TEST_ROOT"] ?? FileManager.default.currentDirectoryPath + "/tmp/tests").appendingPathComponent("audio-assembly-\(UUID().uuidString)")
        paths = AppPaths(root: root)
        try FileManager.default.createDirectory(at: paths.meetingDirectory("test").appendingPathComponent("audio"), withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(at: paths.root) }
    func channelChunk(id: String, values: [Float]) throws -> CapturedChunk {
        let tag = kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(values.count)
        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: tag), "Discrete channel layout must support the synthetic fixture")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, interleaved: false, channelLayout: layout)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000), "Could not allocate the multichannel PCM fixture")
        buffer.frameLength = 48000
        for channel in values.indices { for frame in 0..<48000 { buffer.floatChannelData![channel][frame] = values[channel] } }
        let relative = "audio/\(id).caf", url = paths.meetingDirectory("test").appendingPathComponent("audio/\(id).caf")
        var settings = format.settings; settings[AVLinearPCMIsNonInterleaved] = false
        var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file?.write(from: buffer); file = nil
        return CapturedChunk(id: id, meetingID: "test", epochID: "epoch", track: .remote, relativePath: relative, startTime: 0, duration: 1, sampleRate: 48000, frameCount: 48000, sha256: try AudioWindowAssembler.digest(url))
    }
    func sample(_ url: URL) throws -> Float {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return buffer.floatChannelData![0][8000]
    }
    func chunk(id: String, start: Double, duration: Double, value: Float) throws -> CapturedChunk {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(duration * 48000))!
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<2 { for frame in 0..<Int(buffer.frameLength) { buffer.floatChannelData![channel][frame] = value } }
        let relative = "audio/\(id).caf"
        let url = paths.meetingDirectory("test").appendingPathComponent(relative)
        var settings = format.settings; settings[AVLinearPCMIsNonInterleaved] = false
        var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file?.write(from: buffer); file = nil
        return CapturedChunk(id: id, meetingID: "test", epochID: "epoch", track: .remote, relativePath: relative, startTime: start, duration: duration, sampleRate: 48000, frameCount: Int64(buffer.frameLength), sha256: try AudioWindowAssembler.digest(url))
    }
}

final class ProcessingIdentityTests: XCTestCase {
    func testSpeechWindowsDoNotCrossDeletedGap() {
        let first = CapturedChunk(id: "before", meetingID: "m", epochID: "e", track: .remote,
                                  relativePath: "before.caf", startTime: 0, duration: 10,
                                  sampleRate: 16_000, frameCount: 160_000, sha256: "a")
        let second = CapturedChunk(id: "after", meetingID: "m", epochID: "e", track: .remote,
                                   relativePath: "after.caf", startTime: 20, duration: 10,
                                   sampleRate: 16_000, frameCount: 160_000, sha256: "b")
        let windows = ProcessingIdentity.speechWindows(meetingID: "m", chunks: [first, second], final: true)
        XCTAssertEqual(windows.count, 2)
        XCTAssertTrue(windows.allSatisfy { $0.start + $0.duration <= 10 || $0.start >= 20 })
        XCTAssertNotEqual(windows[0].windowID, windows[1].windowID)
    }
    func testWindowIdentitySurvivesProvisionalGrowthAndFinalization() {
        let first = CapturedChunk(id: "a", meetingID: "m", epochID: "e", track: .remote, relativePath: "a.caf", startTime: 2, duration: 5, sampleRate: 16000, frameCount: 80000, sha256: "a")
        var second = first; second.id = "b"; second.startTime = 7
        let preview = ProcessingIdentity.speechWindows(meetingID: "m", chunks: [first], final: false)[0]
        let growing = ProcessingIdentity.speechWindows(meetingID: "m", chunks: [first, second], final: false)[0]
        let final = ProcessingIdentity.speechWindows(meetingID: "m", chunks: [first, second], final: true)[0]
        XCTAssertEqual(preview.windowID, growing.windowID)
        XCTAssertEqual(growing.windowID, final.windowID)
        XCTAssertNotEqual(ProcessingIdentity.jobID(preview, kind: .transcribe), ProcessingIdentity.jobID(growing, kind: .transcribe))
        XCTAssertNotEqual(ProcessingIdentity.jobID(growing, kind: .transcribe), ProcessingIdentity.jobID(final, kind: .transcribe))
        XCTAssertFalse(final.provisional)
    }
    func testOverlapHasContextOnBothSidesOfNonoverlappingOwnershipRanges() {
        let chunks = (0..<12).map { index in CapturedChunk(id: String(index), meetingID: "m", epochID: "e", track: .remote, relativePath: "x", startTime: Double(index) * 5, duration: 5, sampleRate: 16000, frameCount: 80000, sha256: "x") }
        let windows = ProcessingIdentity.speechWindows(meetingID: "m", chunks: chunks, final: true)
        XCTAssertEqual(windows[0].ownershipEnd, windows[1].ownershipStart)
        XCTAssertLessThan(windows[1].start, windows[1].ownershipStart!)
        XCTAssertGreaterThan(windows[0].start + windows[0].duration, windows[0].ownershipEnd!)
        XCTAssertTrue(windows.allSatisfy { $0.duration <= 30 })
    }
    func testWindowsStayBoundedAndEpochsAndTracksRemainDistinct() {
        let chunks = (0..<14).map { index in CapturedChunk(id: String(index), meetingID: "m", epochID: "e", track: .remote, relativePath: "\(index).caf", startTime: Double(index) * 5, duration: 5, sampleRate: 16000, frameCount: 80000, sha256: "x") }
        let windows = ProcessingIdentity.speechWindows(meetingID: "m", chunks: chunks, final: true)
        XCTAssertEqual(windows.map(\.duration), [29, 30, 15])
        XCTAssertEqual(windows.map(\.start), [0, 27, 55])
        XCTAssertEqual(Set(windows.map(\.windowID)).count, 3)
        var separate = chunks[0]; separate.epochID = "new"
        XCTAssertNotEqual(windows[0].windowID, ProcessingIdentity.speechWindows(meetingID: "m", chunks: [separate], final: true)[0].windowID)
        separate = chunks[0]; separate.track = .microphone
        XCTAssertNotEqual(windows[0].windowID, ProcessingIdentity.speechWindows(meetingID: "m", chunks: [separate], final: true)[0].windowID)
    }
}

final class RegenerationFinalizationTests: XCTestCase {
    func testGeneratingNotesCannotInsertRecordingWindowsIntoAnActivatedVersion() async throws {
        let fixture = try AudioFixture(); defer { fixture.remove() }
        let store = try MeetingStore(paths: fixture.paths)
        let meeting = Meeting(id: "test", title: "History", startedAt: Date(), endedAt: Date(), state: .ready, language: "en", sourceName: "Fixture", usesEchoCancellation: false, transcriptRevision: 0, speechModel: .whisper)
        try store.createMeeting(meeting)
        try store.addChunk(fixture.chunk(id: "raw", start: 0, duration: 2, value: 0.25))
        let config = ProcessingConfiguration(speech: .init(id: "parakeet", revision: String(repeating: "b", count: 40)), notes: .init(id: "notes", revision: String(repeating: "c", count: 40)))
        var version = TranscriptVersion(meetingID: "test", configuration: config, audioFingerprint: "fixture")
        try store.saveTranscriptVersion(version)
        let segment = TranscriptSegment(id: "regenerated", meetingID: "test", windowID: "regenerated-window", track: .remote, startTime: 0, endTime: 2, text: "Preserve this version", speakerID: nil, isUncertain: false, isProvisional: false, isEdited: false)
        try store.saveVersionWindow(versionID: version.id, windowID: segment.windowID, segments: [segment])
        version.status = .ready; try store.saveTranscriptVersion(version); try store.activateTranscriptVersion(version.id, meetingID: "test")
        let processor = MeetingProcessor(store: store, paths: fixture.paths, service: LocalService(paths: fixture.paths), intelligence: LocalIntelligence(modelsURL: fixture.paths.modelsURL))
        try await processor.finalize(meetingID: "test", onUpdate: { _ in })
        XCTAssertEqual(try store.segments(meetingID: "test"), [segment])
        XCTAssertTrue(try store.jobs(meetingID: "test").filter { $0.kind == .transcribe }.isEmpty)
        XCTAssertEqual(try store.meeting(id: "test")?.state, .ready)
        XCTAssertTrue(try store.jobs(meetingID: "test").contains { $0.kind == .notes && $0.status == .failed })
    }
}
