import XCTest
import GRDB
@testable import EchoCore

final class ProductionMeetingTests: XCTestCase {
    func testGroupingDownloadSizeIncludesDependencyManifests() throws {
        let manifest = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("service/models.json")
        let catalog = try ModelCatalog(url: manifest)
        XCTAssertEqual(catalog.downloadBytes(includingDependenciesOf: "diarization"), 32_571_960)
    }
    func testRoomGroupingIsTrackScopedAndRetryDoesNotInvalidateNotesAgain() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ECHO_TEST_ROOT"] ?? FileManager.default.currentDirectoryPath + "/tmp/tests").appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(paths: AppPaths(root: root))
        let meeting = Meeting(id: "room", title: "Room", startedAt: Date(), endedAt: nil, state: .ready, language: "en", sourceName: "Room microphone", usesEchoCancellation: false, transcriptRevision: 0, recordingMode: .inPerson)
        try store.createMeeting(meeting)
        var run = SpeakerGroupingRun(id: "group", meetingID: "room", transcriptVersionID: "legacy-room", track: .remote, model: nil, audioFingerprint: "fixture", partial: false, turns: [.init(start: 0, end: 2, speakerID: "one")])
        XCTAssertThrowsError(try store.saveSpeakerGrouping(run))
        run.track = .microphone
        try store.saveSpeakerGrouping(run)
        try store.saveSpeakerGrouping(run)
        XCTAssertEqual(try store.speakerGroupingRuns(meetingID: "room").count, 1)
        XCTAssertEqual(try store.meeting(id: "room")?.transcriptRevision, 1)
        try store.upsertSpeaker(Speaker(id: "one", meetingID: "room", label: "Speaker 1", isVerified: false))
        let recovered = TranscriptSegment(id: "recovered", meetingID: "room", windowID: "late", track: .microphone, startTime: 0, endTime: 1, text: "Saved speech", speakerID: nil, isUncertain: true, isProvisional: false, isEdited: false)
        try store.replaceSegments(meetingID: "room", windowID: "late", segments: [recovered], isFinal: true)
        let revision = try XCTUnwrap(store.meeting(id: "room")).transcriptRevision
        try store.saveSpeakerGrouping(run, assignments: ["recovered": "one"], reapply: true)
        try store.saveSpeakerGrouping(run, assignments: ["recovered": "one"], reapply: true)
        XCTAssertEqual(try store.meeting(id: "room")?.transcriptRevision, revision + 1)
        XCTAssertEqual(try store.segments(meetingID: "room").first?.speakerID, "one")
        XCTAssertEqual(try store.segments(meetingID: "room").first?.text, "Saved speech")
        XCTAssertEqual(try store.segments(meetingID: "room").first?.isUncertain, true)
        run.id = "other"; run.transcriptVersionID = "wrong-version"
        XCTAssertThrowsError(try store.saveSpeakerGrouping(run))
        XCTAssertEqual(try store.exportSnapshot(meetingID: "room").speakerGrouping?.count, 1)
        let exported = try MeetingExporter(store: store).export(meetingID: "room", to: root.appendingPathComponent("exports"))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(ExportSnapshot.self, from: Data(contentsOf: exported.appendingPathComponent("meeting.json")))
        XCTAssertEqual(manifest.speakerGrouping?.first?.turns, [.init(start: 0, end: 2, speakerID: "one")])
    }

    func testModeSurvivesStorageAndCannotBeChanged() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ECHO_TEST_ROOT"] ?? FileManager.default.currentDirectoryPath + "/tmp/tests").appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(paths: AppPaths(root: root))
        var meeting = Meeting(id: "room", title: "Room", startedAt: Date(), endedAt: nil, state: .recording, language: "en", sourceName: "Microphone", usesEchoCancellation: false, transcriptRevision: 0)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(meeting)) as? [String: Any])
        json["recordingMode"] = "inPerson"
        meeting = try JSONDecoder().decode(Meeting.self, from: JSONSerialization.data(withJSONObject: json))
        try store.createMeeting(meeting)
        let saved = try XCTUnwrap(store.meeting(id: "room"))
        let savedJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        XCTAssertEqual(savedJSON["recordingMode"] as? String, "inPerson")
        json["recordingMode"] = "online"
        let changed = try JSONDecoder().decode(Meeting.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertThrowsError(try store.updateMeeting(changed))
    }

    func testLegacyMeetingDecodesAsOnline() throws {
        let original = Meeting(id: "old", title: "Old", startedAt: Date(), endedAt: nil, state: .ready, language: "en", sourceName: "Mic", usesEchoCancellation: false, transcriptRevision: 0)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json.removeValue(forKey: "recordingMode")
        let decoded = try JSONDecoder().decode(Meeting.self, from: JSONSerialization.data(withJSONObject: json))
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        XCTAssertEqual(encoded["recordingMode"] as? String, "online")
    }
}
