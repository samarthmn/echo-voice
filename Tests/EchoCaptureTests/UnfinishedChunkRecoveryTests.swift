import XCTest
import AVFoundation
import EchoCore
@testable import EchoCapture

final class UnfinishedChunkRecoveryTests: XCTestCase {
    private func fixture() throws -> (URL, AppPaths, MeetingStore) {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ECHO_TEST_ROOT"] ?? FileManager.default.currentDirectoryPath + "/tmp/tests")
        let directory = root.appendingPathComponent("unfinished-recovery-\(UUID().uuidString)")
        let paths = AppPaths(root: directory)
        let store = try MeetingStore(paths: paths)
        try store.createMeeting(Meeting(id: "meeting", title: "Recovery", startedAt: Date(), endedAt: nil, state: .recording, language: "en", sourceName: "Synthetic", usesEchoCancellation: false, transcriptRevision: 0))
        return (directory, paths, store)
    }
    private func writer(paths: AppPaths, onEvent: @escaping @Sendable (CaptureEvent) -> Void = { _ in }) throws -> AudioChunkWriter {
        try AudioChunkWriter(track: .microphone, inputFormat: AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!, configuration: CaptureConfiguration(meetingID: "meeting", meetingDirectory: paths.meetingDirectory("meeting"), application: nil, microphone: nil, allowSingleSource: true), onEvent: onEvent)
    }
    private func append(_ writer: AudioChunkWriter) throws {
        let buffer = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!, frameCapacity: 480)!
        buffer.frameLength = 480
        for index in 0..<480 { buffer.floatChannelData![0][index] = 0.1 }
        _ = try writer.append(buffer, at: 12, epoch: "epoch")
    }
    func testAbandonedChunkPreservesIntentAndBytesAndRecoversExplicitGapIdempotently() throws {
        let (directory, paths, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var pending: AudioChunkWriter? = try writer(paths: paths)
        try append(pending!)
        pending = nil // best-case closed partial; never published via finish()
        let audio = paths.meetingDirectory("meeting").appendingPathComponent("audio")
        let files = try FileManager.default.contentsOfDirectory(at: audio, includingPropertiesForKeys: nil)
        let partial = try XCTUnwrap(files.first { $0.lastPathComponent.hasSuffix("partial.caf") })
        let intentURL = try XCTUnwrap(files.first { $0.lastPathComponent.hasSuffix("intent.json") })
        let intent = try JSONDecoder().decode(CaptureChunkIntent.self, from: Data(contentsOf: intentURL))
        XCTAssertEqual(intent.epochID, "epoch")
        XCTAssertEqual(intent.startTime, 12)
        XCTAssertEqual(intent.sampleRate, 48000)
        XCTAssertEqual(try AVAudioFile(forReading: partial).length, 480)
        for _ in 0..<2 {
            let reopened = try MeetingStore(paths: paths)
            XCTAssertTrue(try reopened.chunks(meetingID: "meeting").isEmpty)
            let gaps = try reopened.gaps(meetingID: "meeting")
            XCTAssertEqual(gaps.count, 1)
            XCTAssertEqual(gaps[0].startTime, 12)
            XCTAssertNil(gaps[0].endTime)
            XCTAssertTrue(gaps[0].reason.contains("not verified"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: intentURL.path))
        }
    }
    func testFinalizedChunkCommitRemovesInitialIntent() throws {
        var cleanup: URL?
        defer { if let cleanup { try? FileManager.default.removeItem(at: cleanup) } }
        try autoreleasepool {
            let (directory, paths, store) = try fixture()
            cleanup = directory
            let recording = try writer(paths: paths) { event in
                if case .chunk(let chunk) = event {
                    do { try store.addChunk(chunk) }
                    catch { XCTFail("Chunk commit failed: \(error)") }
                }
            }
            try append(recording)
            try recording.finish()
            XCTAssertEqual(try store.chunks(meetingID: "meeting").count, 1)
            let files = try FileManager.default.contentsOfDirectory(at: paths.meetingDirectory("meeting").appendingPathComponent("audio"), includingPropertiesForKeys: nil)
            XCTAssertFalse(files.contains { $0.lastPathComponent.hasSuffix("intent.json") })
            let reopened = try MeetingStore(paths: paths)
            XCTAssertTrue(try reopened.gaps(meetingID: "meeting").isEmpty)
        } // release writer callback and both stores before removing SQLite files
    }
    func testIntentRejectsCrossMeetingAndTraversalMetadata() throws {
        let (directory, paths, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = paths.meetingDirectory("meeting").appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        let url = audio.appendingPathComponent("microphone-intent.caf.intent.json")
        var intent = CaptureChunkIntent(id: "intent", meetingID: "different", epochID: "epoch", track: .microphone, relativePath: "audio/microphone-intent.caf", startTime: 12, sampleRate: 48000, channels: 1)
        try JSONEncoder().encode(intent).write(to: url)
        XCTAssertThrowsError(try MeetingStore(paths: paths))
        intent.meetingID = "meeting"; intent.relativePath = "../outside.caf"
        try JSONEncoder().encode(intent).write(to: url)
        XCTAssertThrowsError(try MeetingStore(paths: paths))
    }
}
