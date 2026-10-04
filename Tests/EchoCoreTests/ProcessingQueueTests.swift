import Foundation
import XCTest
@testable import EchoCore

final class ProcessingQueueTests: XCTestCase {
    func testQueueSurvivesReopenDeduplicatesAndPreservesOrder() throws {
        let root = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["ECHO_TEST_ROOT"]))
            .appendingPathComponent("queue-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        let store = try MeetingStore(paths: paths)
        for id in ["first", "second"] {
            try store.createMeeting(Meeting(id: id, title: id, startedAt: Date(), endedAt: Date(), state: .finalizing,
                language: "en", sourceName: "Synthetic", usesEchoCancellation: false, transcriptRevision: 0))
        }
        try store.enqueueProcessing(meetingID: "first")
        try store.enqueueProcessing(meetingID: "second")
        try store.enqueueProcessing(meetingID: "first", windowedSpeakers: true)
        try store.waitForProcessingModels(meetingID: "first")
        let reopened = try MeetingStore(paths: paths)
        let queue = try reopened.processingQueue()
        XCTAssertEqual(queue.map(\.meetingID), ["first", "second"])
        XCTAssertTrue(queue[0].windowedSpeakers)
        XCTAssertTrue(queue[0].waitingForModels)
        try reopened.enqueueProcessing(meetingID: "first")
        XCTAssertFalse(try XCTUnwrap(reopened.processingQueue().first).waitingForModels)
        try reopened.finishQueuedProcessing(meetingID: "first")
        XCTAssertEqual(try reopened.processingQueue().map(\.meetingID), ["second"])
        try reopened.deleteMeeting(id: "second")
        XCTAssertTrue(try reopened.processingQueue().isEmpty)
    }
}
