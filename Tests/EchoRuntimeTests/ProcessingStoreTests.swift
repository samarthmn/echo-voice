import XCTest
import EchoCore
@testable import EchoRuntime

final class ProcessingStoreTests: XCTestCase {
    func testReplanningCannotResetPersistedRetryStateOrDuplicateAJob() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ECHO_TEST_ROOT"] ?? FileManager.default.currentDirectoryPath + "/tmp/tests").appendingPathComponent("scheduler-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(paths: AppPaths(root: root))
        try store.createMeeting(Meeting(id: "test", title: "Test", startedAt: Date(), endedAt: nil, state: .recording, language: "en", sourceName: "Fixture", usesEchoCancellation: false, transcriptRevision: 0))
        let window = ProcessingWindow(track: .remote, epochID: "epoch", start: 0, duration: 5, windowID: ProcessingIdentity.id("test", "window"), provisional: true, relativePath: "derived/asr.wav")
        let id = ProcessingIdentity.jobID(window, kind: .transcribe)
        let original = ProcessingJob(id: id, meetingID: "test", kind: .transcribe, status: .pending, payload: String(decoding: try JSONEncoder().encode(window), as: UTF8.self), attempts: 0, error: nil, createdAt: Date())
        try store.enqueue(original)
        var failed = original; failed.status = .failed; failed.attempts = 2; failed.error = "Local worker unavailable"
        try store.updateJob(failed)
        try store.enqueue(original)
        let jobs = try store.jobs(meetingID: "test")
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs[0].attempts, 2)
        XCTAssertEqual(jobs[0].status, .failed)
        XCTAssertEqual(jobs[0].id, id)
    }
}
