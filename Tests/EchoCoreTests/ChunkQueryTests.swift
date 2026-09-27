import Foundation
import XCTest
@testable import EchoCore

final class ChunkQueryTests: XCTestCase {
    func testIncrementalCursorAndBoundedOverlapQuery() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ECHO_TEST_ROOT"] ?? FileManager.default.currentDirectoryPath + "/tmp/tests")
            .appendingPathComponent("chunk-query-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(paths: AppPaths(root: root))
        try store.createMeeting(Meeting(id: "meeting", title: "Cursor", startedAt: Date(), endedAt: nil,
                                        state: .recording, language: "en", sourceName: "Synthetic",
                                        usesEchoCancellation: false, transcriptRevision: 0))
        func save(_ id: String, track: AudioTrack, start: Double) throws {
            let file = try store.paths.resolveMeetingAsset(meetingID: "meeting", relativePath: "audio/\(id).caf")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1]).write(to: file)
            try store.addChunk(CapturedChunk(id: id, meetingID: "meeting", epochID: "epoch",
                                             track: track, relativePath: "audio/\(id).caf",
                                             startTime: start, duration: 5, sampleRate: 48_000,
                                             frameCount: 240_000, sha256: try MeetingStore.sha256(file)))
        }
        try save("early", track: .remote, start: 0)
        let first = try store.chunksAdded(meetingID: "meeting", afterRowID: 0)
        XCTAssertEqual(first.map { $0.chunk.id }, ["early"])
        try save("late", track: .microphone, start: 5)
        XCTAssertEqual(try store.chunksAdded(meetingID: "meeting", afterRowID: first[0].rowID)
            .map { $0.chunk.id }, ["late"])
        XCTAssertEqual(try store.chunksOverlapping(meetingID: "meeting", track: .microphone,
                                                   start: 4, end: 7).map(\.id), ["late"])
        XCTAssertTrue(try store.chunksOverlapping(meetingID: "meeting", track: .remote,
                                                  start: 5, end: 10).isEmpty)
    }
}
