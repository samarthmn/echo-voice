import XCTest
@testable import EchoCore

final class SpeakerPreviewTests: XCTestCase {
    func testSelectsSourceTrackAndExcludesDeletedInterval() {
        let run = SpeakerGroupingRun(id: "run", meetingID: "meeting", transcriptVersionID: "version",
                                     track: .remote, model: nil, audioFingerprint: "fingerprint", partial: false,
                                     turns: [.init(start: 0, end: 10, speakerID: "one"),
                                             .init(start: 9, end: 15, speakerID: "two")])
        let chunks = [CapturedChunk(id: "remote", meetingID: "meeting", epochID: "epoch", track: .remote,
                                    relativePath: "remote.caf", startTime: 0, duration: 15,
                                    sampleRate: 48_000, frameCount: 720_000, sha256: "hash"),
                      CapturedChunk(id: "mic", meetingID: "meeting", epochID: "epoch", track: .microphone,
                                    relativePath: "mic.caf", startTime: 0, duration: 15,
                                    sampleRate: 48_000, frameCount: 720_000, sha256: "hash")]
        let samples = SpeakerPreviewSelector.previews(for: run, coverage: chunks, redactions: [2..<5])
        XCTAssertEqual(samples["one"]?.first?.track, .remote)
        XCTAssertTrue(samples["one"]?.allSatisfy { $0.end <= 2 || $0.start >= 5 } == true)
        XCTAssertTrue(samples["one"]?.allSatisfy { $0.end - $0.start <= 8 } == true)
        XCTAssertEqual(samples["two"]?.first?.start, 10)
        XCTAssertEqual(samples["two"]?.first?.overlapsAnotherSpeaker, false)
    }
}
