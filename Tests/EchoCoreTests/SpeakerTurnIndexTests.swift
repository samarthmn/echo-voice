import Foundation
import XCTest
@testable import EchoCore

final class SpeakerTurnIndexTests: XCTestCase {
    func testIndexedAttributionMatchesOverlappingTurns() {
        let run = SpeakerGroupingRun(id: "run", meetingID: "meeting", transcriptVersionID: "legacy-meeting", track: .remote,
                                     model: nil, audioFingerprint: "fixture", partial: false,
                                     turns: [SpeakerTurn(start: 0, end: 2, speakerID: "one"),
                                             SpeakerTurn(start: 1, end: 3, speakerID: "two"),
                                             SpeakerTurn(start: 3, end: 4, speakerID: "two")])
        let segment = TranscriptSegment(id: "segment", meetingID: "meeting", windowID: "window", track: .remote,
                                        startTime: 0, endTime: 4, text: "One two three", speakerID: nil,
                                        isUncertain: false, isProvisional: false, isEdited: false,
                                        words: [
                                            TranscriptWord(id: "one", text: "One", location: 0, length: 3, start: 0.5, end: 0.8, source: .nativeWord),
                                            TranscriptWord(id: "two", text: "two", location: 4, length: 3, start: 1.5, end: 1.8, source: .nativeWord),
                                            TranscriptWord(id: "three", text: "three", location: 8, length: 5, start: 3.2, end: 3.5, source: .nativeWord),
                                        ])
        XCTAssertEqual(SpeakerTurnIndex(run: run).spans(segment: segment), SpeakerAttribution.spans(segment: segment, run: run))
    }
}
