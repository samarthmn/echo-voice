import XCTest
import EchoCore
@testable import EchoRuntime

final class NotesGenerationQueueTests: XCTestCase {
    private var root: URL!
    private var store: MeetingStore!
    override func setUpWithError() throws {
        root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ECHO_TEST_ROOT"] ?? FileManager.default.currentDirectoryPath + "/tmp/tests").appendingPathComponent("notes-retry-\(UUID().uuidString)")
        store = try MeetingStore(paths: AppPaths(root: root))
        try store.createMeeting(Meeting(id: "meeting", title: "Notes fixture", startedAt: Date(), endedAt: Date(), state: .finalizing, language: "en", sourceName: "Fixture", usesEchoCancellation: false, transcriptRevision: 0))
    }
    override func tearDownWithError() throws {
        store = nil
        try FileManager.default.removeItem(at: root)
    }
    private func draft(partial: Bool) -> MeetingNotes {
        MeetingNotes(id: UUID().uuidString, meetingID: "meeting", createdAt: Date(), transcriptRevision: 0, summary: [NoteItem(id: "item", text: "A supported summary", evidenceIDs: ["segment"])], decisions: [], actionItems: [], isEdited: false, isPartial: partial)
    }

    func testPartialDraftIsRetryableAndNewAttemptPreservesEarlierEdits() throws {
        let queue = NotesGenerationQueue(store: store)
        var first = try queue.enqueue(meetingID: "meeting", evidenceVersion: "same-evidence")
        XCTAssertThrowsError(try queue.save(draft(partial: true), job: first, hasIncompleteEvidence: false))
        first.status = .failed; first.attempts = 3; try store.updateJob(first)
        var edited = try XCTUnwrap(store.notes(meetingID: "meeting").first)
        edited.isEdited = true; edited.summary[0].text = "My correction"
        try store.saveNotes(edited)

        let retry = try queue.enqueue(meetingID: "meeting", evidenceVersion: "same-evidence")
        XCTAssertNotEqual(first.id, retry.id)
        XCTAssertEqual(retry.status, .pending)
        XCTAssertEqual(retry.attempts, 0)
        try queue.save(draft(partial: false), job: retry, hasIncompleteEvidence: false)
        let versions = try store.notes(meetingID: "meeting")
        XCTAssertEqual(versions.count, 2)
        XCTAssertEqual(versions.first { $0.id == first.id }, edited)
        XCTAssertEqual(try store.jobs(meetingID: "meeting").first { $0.id == first.id }?.status, .cancelled)
    }

    func testUnfinishedAttemptResumesAfterStoreReopenWithoutDuplicatingJob() throws {
        let first = try NotesGenerationQueue(store: store).enqueue(meetingID: "meeting", evidenceVersion: "evidence")
        store = nil
        store = try MeetingStore(paths: AppPaths(root: root))
        let resumed = try NotesGenerationQueue(store: store).enqueue(meetingID: "meeting", evidenceVersion: "evidence")
        XCTAssertEqual(resumed.id, first.id)
        XCTAssertEqual(try store.jobs(meetingID: "meeting").count, 1)
    }

    func testSavedDraftSurvivesCrashBeforeJobCompletionAndExplicitRegeneration() throws {
        let queue = NotesGenerationQueue(store: store)
        let first = try queue.enqueue(meetingID: "meeting", evidenceVersion: "evidence")
        try queue.save(draft(partial: false), job: first, hasIncompleteEvidence: false)
        // The draft commit succeeded, but the process died before updating the job.
        let second = try queue.enqueue(meetingID: "meeting", evidenceVersion: "evidence")
        XCTAssertNotEqual(first.id, second.id)
        try queue.save(draft(partial: false), job: second, hasIncompleteEvidence: false)
        var completed = second; completed.status = .completed; try store.updateJob(completed)
        let third = try queue.enqueue(meetingID: "meeting", evidenceVersion: "evidence")
        XCTAssertNotEqual(second.id, third.id)
        XCTAssertEqual(try store.notes(meetingID: "meeting").count, 2)
    }

    func testIncompleteUpstreamEvidenceLabelsSavedDraftWithoutDiscardingIt() throws {
        let queue = NotesGenerationQueue(store: store)
        let job = try queue.enqueue(meetingID: "meeting", evidenceVersion: "evidence")
        try queue.save(draft(partial: false), job: job, hasIncompleteEvidence: true)
        XCTAssertTrue(try XCTUnwrap(store.notes(meetingID: "meeting").first).isPartial)
    }
}
