import Foundation
import XCTest
@testable import EchoCore

final class MicrophoneProcessingEpochTests: XCTestCase {
    func testAcousticChoiceIsFrozenPerMicrophoneEpoch() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ECHO_TEST_ROOT"] ?? FileManager.default.currentDirectoryPath + "/tmp/tests")
            .appendingPathComponent("microphone-epochs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(paths: AppPaths(root: root))
        try store.createMeeting(Meeting(id: "meeting", title: "Epochs", startedAt: Date(), endedAt: nil,
                                        state: .recording, language: "en", sourceName: "Test",
                                        usesEchoCancellation: false, transcriptRevision: 0))
        let first = MicrophoneProcessingEpoch(meetingID: "meeting", epochID: "headphones", startTime: 0,
                                              sampleRate: 48_000, channels: 1, acousticMode: .headphones)
        let second = MicrophoneProcessingEpoch(meetingID: "meeting", epochID: "speakers", startTime: 10,
                                               sampleRate: 48_000, channels: 1, acousticMode: .speakerphone)
        try store.saveMicrophoneProcessingEpoch(first)
        try store.saveMicrophoneProcessingEpoch(second)
        XCTAssertEqual(try store.microphoneProcessingEpochs(meetingID: "meeting"), [first, second])
        XCTAssertThrowsError(try store.saveMicrophoneProcessingEpoch(.init(meetingID: "meeting", epochID: "headphones",
                                                                     startTime: 0, sampleRate: 48_000, channels: 1,
                                                                     acousticMode: .speakerphone)))
    }
}
