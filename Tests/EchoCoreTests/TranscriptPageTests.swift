import Foundation
import XCTest
@testable import EchoCore

final class TranscriptPageTests: XCTestCase {
    func testFirstProvisionalPassageAdvancesTimelineRevision() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ECHO_TEST_ROOT"] ?? FileManager.default.currentDirectoryPath + "/tmp/tests")
            .appendingPathComponent("first-live-revision-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(paths: AppPaths(root: root))
        try store.createMeeting(Meeting(id: "meeting", title: "Live", startedAt: Date(), endedAt: nil,
                                        state: .recording, language: "en", sourceName: "Test",
                                        usesEchoCancellation: false, transcriptRevision: 0))
        let segment = TranscriptSegment(id: "first", meetingID: "meeting", windowID: "window", track: .remote,
                                        startTime: 0, endTime: 1, text: "first words", speakerID: nil,
                                        isUncertain: false, isProvisional: true, isEdited: false)
        try store.replaceSegments(meetingID: "meeting", windowID: "window", segments: [segment])
        XCTAssertEqual(try store.transcriptTimeline(meetingID: "meeting", versionID: "legacy-meeting").transcriptRevision, 1)
    }

    func testPagesKeepEqualTimestampOrderAndFetchOnlyRequestedPayloads() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ECHO_TEST_ROOT"] ?? FileManager.default.currentDirectoryPath + "/tmp/tests")
            .appendingPathComponent("transcript-pages-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(paths: AppPaths(root: root))
        let meetingID = "paged-meeting"
        try store.createMeeting(Meeting(id: meetingID, title: "Pages", startedAt: Date(), endedAt: Date(), state: .ready, language: "en", sourceName: "Test", usesEchoCancellation: false, transcriptRevision: 0))
        let segments: [TranscriptSegment] = (0..<6).map { index in
            let start = index < 3 ? 0.0 : Double(index)
            let end = index < 3 ? Double(3 - index) : Double(index + 1)
            return TranscriptSegment(id: "segment-\(index)", meetingID: meetingID, windowID: "window", track: .remote,
                                     startTime: start, endTime: end, text: "payload \(index)", speakerID: nil,
                                     isUncertain: false, isProvisional: false, isEdited: false)
        }
        try store.replaceSegments(meetingID: meetingID, windowID: "window", segments: segments, isFinal: true)
        let versionID = try store.activeTranscriptVersion(meetingID: meetingID)

        let identities = try store.transcriptRowIdentities(meetingID: meetingID, versionID: versionID)
        XCTAssertEqual(identities.map(\.id), ["segment-2", "segment-1", "segment-0", "segment-3", "segment-4", "segment-5"])
        let first = try store.transcriptPage(.init(meetingID: meetingID, versionID: versionID, anchor: nil, direction: .forward, limit: 2))
        XCTAssertEqual(first.rows.map(\.id), ["segment-2", "segment-1"])
        XCTAssertNotNil(first.followingCursor)
        let second = try store.transcriptPage(.init(meetingID: meetingID, versionID: versionID, anchor: first.followingCursor, direction: .forward, limit: 2))
        XCTAssertEqual(second.rows.map(\.id), ["segment-0", "segment-3"])
        let backward = try store.transcriptPage(.init(meetingID: meetingID, versionID: versionID, anchor: second.rows.first?.id, direction: .backward, limit: 2))
        XCTAssertEqual(backward.rows.map(\.id), first.rows.map(\.id))
        XCTAssertEqual(try store.segment(meetingID: meetingID, versionID: versionID, segmentID: "segment-4")?.text, "payload 4")

        let archived = TranscriptVersion(id: "archived", meetingID: meetingID, status: .building,
                                         configuration: nil, audioFingerprint: "fixture")
        try store.saveTranscriptVersion(archived)
        let historic = segments.prefix(3).map { segment -> TranscriptSegment in
            var copy = segment
            copy.windowID = "historic-window"
            return copy
        }
        try store.saveVersionWindow(versionID: archived.id, windowID: "historic-window", segments: historic)
        XCTAssertEqual(try store.transcriptRowIdentities(meetingID: meetingID, versionID: archived.id).map(\.id),
                       ["segment-2", "segment-1", "segment-0"])
        let archivedPage = try store.transcriptPage(.init(meetingID: meetingID, versionID: archived.id,
                                                          anchor: nil, direction: .forward, limit: 2))
        XCTAssertEqual(archivedPage.rows.map(\.id), ["segment-2", "segment-1"])
    }
}
