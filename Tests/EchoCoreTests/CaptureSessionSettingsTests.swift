import Foundation
import XCTest
@testable import EchoCore

final class CaptureSessionSettingsTests: XCTestCase {
    func testSpeakerphoneSettingsRequireBothSelectedSources() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ECHO_TEST_ROOT"] ?? FileManager.default.currentDirectoryPath + "/tmp/tests")
            .appendingPathComponent("acoustic-inputs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(paths: AppPaths(root: root))
        try store.createMeeting(Meeting(id: "meeting", title: "Inputs", startedAt: Date(), endedAt: nil,
                                        state: .recording, language: "en", sourceName: "Fixture",
                                        usesEchoCancellation: false, transcriptRevision: 0))
        for settings in [
            CaptureSessionSettings(microphoneUID: "mic", applicationID: nil, microphoneMuted: false, acousticMode: .speakerphone),
            CaptureSessionSettings(microphoneUID: nil, applicationID: "app", microphoneMuted: false, acousticMode: .speakerphone)
        ] {
            XCTAssertThrowsError(try store.setCaptureSessionSettings(meetingID: "meeting", settings: settings))
        }
    }

    func testResumeAllowsExplicitSourceAndAcousticChangesWithoutRewritingHistoricalPolicy() throws {
        let meeting = Meeting(id: "meeting", title: "Resume", startedAt: Date(), endedAt: nil,
                              state: .interrupted, language: "en", sourceName: "Original app",
                              usesEchoCancellation: false, transcriptRevision: 0)
        let saved = CaptureSessionSettings(microphoneUID: "mic-current", applicationID: "app-current",
                                           microphoneMuted: false, acousticMode: .speakerphone)
        XCTAssertNoThrow(try CaptureResumePolicy.validate(meeting: meeting, saved: saved,
                                                            mode: .online, applicationID: "app-current",
                                                            microphoneUID: "mic-current", acousticMode: .speakerphone))
        XCTAssertNoThrow(try CaptureResumePolicy.validate(meeting: meeting, saved: saved,
                                                            mode: .online, applicationID: "new-explicit-app",
                                                            microphoneUID: "mic-current", acousticMode: .headphones))
        XCTAssertThrowsError(try CaptureResumePolicy.validate(meeting: meeting, saved: saved,
                                                               mode: .online, applicationID: nil,
                                                               microphoneUID: "mic-current", acousticMode: .speakerphone))
    }

    func testSettingsAndTrackEventsSurviveReopenWithLegacyDefaults() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ECHO_TEST_ROOT"] ?? FileManager.default.currentDirectoryPath + "/tmp/tests")
            .appendingPathComponent("capture-settings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var store: MeetingStore? = try MeetingStore(paths: AppPaths(root: root))
        try store?.createMeeting(Meeting(id: "meeting", title: "Capture", startedAt: Date(), endedAt: nil,
                                         state: .recording, language: "en", sourceName: "Test",
                                         usesEchoCancellation: true, transcriptRevision: 0))
        XCTAssertEqual(try store!.captureSessionSettings(meetingID: "meeting").acousticMode, CaptureAcousticMode.speakerphone)
        let settings = CaptureSessionSettings(microphoneUID: "stable-uid", applicationID: "app-id",
                                              microphoneMuted: true, acousticMode: .speakerphone)
        try store?.setCaptureSessionSettings(meetingID: "meeting", settings: settings)
        let event = CaptureTrackEvent(id: "mute", meetingID: "meeting", track: .microphone,
                                      startTime: 4, endTime: nil, cause: .userMute, epochID: "epoch")
        try store?.saveCaptureTrackEvent(event)
        store = nil
        store = try MeetingStore(paths: AppPaths(root: root))
        XCTAssertEqual(try store!.captureSessionSettings(meetingID: "meeting"), settings)
        XCTAssertEqual(try store!.captureTrackEvents(meetingID: "meeting"), [event])
    }
}
