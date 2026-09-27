import Foundation
import XCTest
@testable import EchoCore

final class LiveTranscriptionPolicyTests: XCTestCase {
    func testInitialChoiceAndOneWayStopSurviveReopen() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ECHO_TEST_ROOT"] ?? FileManager.default.currentDirectoryPath + "/tmp/tests")
            .appendingPathComponent("live-policy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var store = try MeetingStore(paths: AppPaths(root: root))
        try store.createMeeting(Meeting(id: "meeting", title: "Policy", startedAt: Date(), endedAt: nil,
                                        state: .recording, language: "en", sourceName: "Test",
                                        usesEchoCancellation: false, transcriptRevision: 0))
        XCTAssertEqual(try store.liveTranscriptionPolicy(meetingID: "meeting"), .init(enabledAtStart: true))
        try store.setInitialLiveTranscriptionPolicy(meetingID: "meeting", enabled: true)
        XCTAssertTrue(try store.liveTranscriptionPolicy(meetingID: "meeting").admitsLiveRecognition)
        XCTAssertEqual(try store.stopLiveTranscription(meetingID: "meeting", effectiveTime: 10), 10)
        XCTAssertEqual(try store.stopLiveTranscription(meetingID: "meeting", effectiveTime: 20), 10)
        store = try MeetingStore(paths: AppPaths(root: root))
        XCTAssertFalse(try store.liveTranscriptionPolicy(meetingID: "meeting").admitsLiveRecognition)
        XCTAssertEqual(try store.liveTranscriptionPolicy(meetingID: "meeting").stoppedAt, 10)
        XCTAssertThrowsError(try store.setInitialLiveTranscriptionPolicy(meetingID: "meeting", enabled: false))
    }

    func testStartingOffNeverAdmitsLiveRecognition() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ECHO_TEST_ROOT"] ?? FileManager.default.currentDirectoryPath + "/tmp/tests")
            .appendingPathComponent("live-off-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(paths: AppPaths(root: root))
        try store.createMeeting(Meeting(id: "meeting", title: "Policy", startedAt: Date(), endedAt: nil,
                                        state: .recording, language: "en", sourceName: "Test",
                                        usesEchoCancellation: false, transcriptRevision: 0))
        try store.setInitialLiveTranscriptionPolicy(meetingID: "meeting", enabled: false)
        XCTAssertFalse(try store.liveTranscriptionPolicy(meetingID: "meeting").admitsLiveRecognition)
    }
}
