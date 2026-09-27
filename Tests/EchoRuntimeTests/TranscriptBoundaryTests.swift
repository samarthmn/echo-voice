import XCTest
import EchoCore
@testable import EchoRuntime

final class TranscriptBoundaryTests: XCTestCase {
    func testNeighborPlanningDoesNotConstructHistoricalSpeechWindows() {
        let source = CapturedChunk(id: "c", meetingID: "m", epochID: "e", track: .remote,
                                   relativePath: "audio/a.caf", startTime: 0, duration: 28_800,
                                   sampleRate: 16_000, frameCount: 460_800_000, sha256: "hash")
        let full = ProcessingIdentity.speechWindows(meetingID: "m", chunks: [source], final: true)
        let lower = 28.0 * 900
        let upper = lower + 56
        let bounded = ProcessingIdentity.speechWindows(meetingID: "m", chunks: [source], final: true,
                                                       minimumOwnershipStart: lower,
                                                       maximumOwnershipStart: upper)
        XCTAssertEqual(bounded.count, 3)
        XCTAssertEqual(bounded, full.filter { ($0.ownershipStart ?? 0) >= lower &&
                                             ($0.ownershipStart ?? 0) <= upper })
    }

    func testRetryPlansOnlyAudioWithoutCompletedTranscriptOwnership() {
        let chunk = CapturedChunk(id: "c", meetingID: "m", epochID: "e", track: .remote,
                                  relativePath: "audio/a.caf", startTime: 0, duration: 90,
                                  sampleRate: 16_000, frameCount: 1_440_000, sha256: "hash")
        let completed = [
            CompletedSpeechWindow(windowID: "old-1", track: .remote, epochID: "e", ownershipStart: 0, ownershipEnd: 28),
            CompletedSpeechWindow(windowID: "old-2", track: .remote, epochID: "e", ownershipStart: 56, ownershipEnd: 84)
        ]
        let remaining = RetainedSpeechCoverage.uncoveredChunks([chunk], completed: completed)
        XCTAssertEqual(remaining.map(\.startTime), [28, 84])
        XCTAssertEqual(remaining.map(\.duration), [28, 6])
        let windows = ProcessingIdentity.speechWindows(meetingID: "m", chunks: remaining, final: true)
        XCTAssertTrue(windows.allSatisfy { window in
            let end = window.start + window.duration
            return (window.start >= 28 && end <= 56) || (window.start >= 84 && end <= 90)
        })
    }

    func testRetainedBoundaryPassageExtendsCompletedOwnershipBeforeRetry() {
        let completed = [CompletedSpeechWindow(windowID: "old", track: .remote, epochID: "e",
                                               ownershipStart: 0, ownershipEnd: 28)]
        let retained = TranscriptSegment(id: "corrected", meetingID: "m", windowID: "old", track: .remote,
                                         startTime: 27, endTime: 29, text: "Corrected shared words",
                                         speakerID: nil, isUncertain: false, isProvisional: false,
                                         isEdited: true)
        let expanded = RetainedSpeechCoverage.extending(completed, with: [retained],
                                                        excluding: 50..<52)
        XCTAssertEqual(expanded.first?.ownershipEnd, 29)
        let source = CapturedChunk(id: "c", meetingID: "m", epochID: "e", track: .remote,
                                   relativePath: "audio/a.caf", startTime: 0, duration: 56,
                                   sampleRate: 16_000, frameCount: 896_000, sha256: "hash")
        XCTAssertEqual(RetainedSpeechCoverage.uncoveredChunks([source], completed: expanded).first?.startTime, 29)
    }

    func testSpeechModelsHaveSeparateStableWindowIDs() throws {
        let chunk = CapturedChunk(id: "c", meetingID: "m", epochID: "e", track: .remote, relativePath: "audio/a.caf", startTime: 0, duration: 10, sampleRate: 16000, frameCount: 160000, sha256: "hash")
        let legacy = ProcessingIdentity.speechWindows(meetingID: "m", chunks: [chunk], final: true)
        let whisper = ProcessingIdentity.speechWindows(meetingID: "m", chunks: [chunk], final: true, model: .whisper)
        let parakeet = ProcessingIdentity.speechWindows(meetingID: "m", chunks: [chunk], final: true, model: .parakeet)
        let legacyHealth = Data(#"{"status":"ready","capabilities":{"transcribe":true,"prepare_audio":true,"diarize":false},"models":{}}"#.utf8)
        XCTAssertFalse(try JSONDecoder().decode(ServiceHealth.self, from: legacyHealth).canTranscribe(.whisper), "Old runtimes must request repair, not claim support for the new request contract")
        XCTAssertEqual(legacy, whisper)
        XCTAssertNotEqual(whisper.first?.windowID, parakeet.first?.windowID)
        XCTAssertEqual(parakeet, ProcessingIdentity.speechWindows(meetingID: "m", chunks: [chunk], final: true, model: .parakeet))
    }

    func testDifferentSegmentIntervalsDoNotRepeatSharedBoundaryWords() {
        let snapshots = [snapshot("left", start: 0, owner: 0, segments: [segment("a", window: "left", start: 26, end: 29, text: "We should ship the release")]), snapshot("right", start: 27, owner: 28, segments: [segment("b", window: "right", start: 27, end: 30, text: "Ship the release tomorrow.")])]
        let result = LexicalBoundaryReconciler.reconcile(snapshots, existing: [])
        XCTAssertEqual(result[0].segments.map(\.text), ["We should ship the release"])
        XCTAssertEqual(result[1].segments.map(\.text), ["tomorrow."])
        XCTAssertEqual(result[1].segments[0].id, "b")
        XCTAssertTrue(result[1].segments[0].isUncertain)
    }
    func testSingleDistinctiveBoundaryWordIsNotRepeated() {
        let left = snapshot("left", start: 0, owner: 0, segments: [segment("a", window: "left", start: 26, end: 29, text: "Ship release")])
        let right = snapshot("right", start: 27, owner: 28, segments: [segment("b", window: "right", start: 27.5, end: 30, text: "release tomorrow")])
        XCTAssertEqual(LexicalBoundaryReconciler.reconcile([left, right], existing: [])[1].segments.map(\.text), ["tomorrow"])
    }
    func testGenuineRepeatedWordAfterBoundaryIsPreserved() {
        let left = snapshot("left", start: 0, owner: 0, segments: [segment("a", window: "left", start: 26, end: 27.9, text: "hello")])
        let right = snapshot("right", start: 27, owner: 28, segments: [segment("b", window: "right", start: 28.1, end: 29, text: "hello")])
        let result = LexicalBoundaryReconciler.reconcile([left, right], existing: [])
        XCTAssertEqual(result[0].segments.map(\.text), ["hello"])
        XCTAssertEqual(result[1].segments.map(\.text), ["hello"])
    }
    func testContextSegmentWithEarlyMidpointRetainsItsNewFinalWord() {
        let snapshots = [snapshot("left", start: 0, owner: 0, segments: [segment("a", window: "left", start: 26, end: 28, text: "ship the release")]), snapshot("right", start: 27, owner: 28, segments: [segment("b", window: "right", start: 27, end: 28.5, text: "ship the release tomorrow")])]
        XCTAssertLessThan((27 + 28.5) / 2, snapshots[1].window.ownershipStart!)
        XCTAssertEqual(LexicalBoundaryReconciler.reconcile(snapshots, existing: [])[1].segments.map(\.text), ["tomorrow"])
    }
    func testDuplicatePrefixCanCrossWhisperSegmentBoundaries() {
        let snapshots = [snapshot("left", start: 0, owner: 0, segments: [segment("a", window: "left", start: 26, end: 29, text: "We will ship the release")]), snapshot("right", start: 27, owner: 28, segments: [segment("b", window: "right", start: 27, end: 28.3, text: "Ship the"), segment("c", window: "right", start: 28.3, end: 30, text: "release tomorrow")])]
        let result = LexicalBoundaryReconciler.reconcile(snapshots, existing: [])
        XCTAssertEqual(result[1].segments.map(\.id), ["c"])
        XCTAssertEqual(result[1].segments.map(\.text), ["tomorrow"])
    }
    func testHumanEditSurvivesEvenWhenItsMachineSegmentIsDuplicate() {
        let left = snapshot("left", start: 0, owner: 0, segments: [segment("a", window: "left", start: 26, end: 29, text: "ship the release")])
        let right = snapshot("right", start: 27, owner: 28, segments: [segment("b", window: "right", start: 27, end: 29, text: "ship the release")])
        var edited = right.segments[0]; edited.text = "Ship release 2, corrected by me"; edited.isEdited = true
        let result = LexicalBoundaryReconciler.reconcile([left, right], existing: [edited])
        XCTAssertEqual(result[1].segments[0].text, edited.text)
        XCTAssertTrue(result[1].segments[0].isEdited)
        XCTAssertEqual(result[1].segments[0].id, edited.id)
    }
    func testChangedEarlierSnapshotRestoresWordsPreviouslyTrimmedFromLaterSnapshot() {
        let later = snapshot("right", start: 27, owner: 28, segments: [segment("b", window: "right", start: 27, end: 30, text: "ship the release tomorrow")])
        let first = snapshot("left", start: 0, owner: 0, segments: [segment("a", window: "left", start: 26, end: 29, text: "ship the release")])
        XCTAssertEqual(LexicalBoundaryReconciler.reconcile([first, later], existing: [])[1].segments[0].text, "tomorrow")
        let revised = snapshot("left", start: 0, owner: 0, segments: [segment("a", window: "left", start: 26, end: 27.5, text: "The previous topic ended")])
        XCTAssertEqual(LexicalBoundaryReconciler.reconcile([revised, later], existing: [])[1].segments[0].text, "ship the release tomorrow")
    }
    func testRemoteFingerprintChangesOnAppendHashOrTimingButNotEnumerationOrder() {
        var chunk = CapturedChunk(id: "a", meetingID: "m", epochID: "e", track: .remote, relativePath: "audio/a.caf", startTime: 0, duration: 5, sampleRate: 48000, frameCount: 240000, sha256: "aaa")
        let original = ProcessingIdentity.recordingFingerprint([chunk])
        var second = chunk; second.id = "b"; second.startTime = 5
        XCTAssertNotEqual(original, ProcessingIdentity.recordingFingerprint([chunk, second]))
        let before = ProcessingIdentity.diarizationWindow(meetingID: "m", chunks: [chunk], windowSeconds: nil)
        let after = ProcessingIdentity.diarizationWindow(meetingID: "m", chunks: [chunk, second], windowSeconds: nil)
        let fallback = ProcessingIdentity.diarizationWindow(meetingID: "m", chunks: [chunk, second], windowSeconds: 1800)
        XCTAssertNotEqual(ProcessingIdentity.jobID(before, kind: .diarize), ProcessingIdentity.jobID(after, kind: .diarize))
        XCTAssertNotEqual(ProcessingIdentity.jobID(after, kind: .diarize), ProcessingIdentity.jobID(fallback, kind: .diarize))
        XCTAssertEqual(ProcessingIdentity.recordingFingerprint([chunk, second]), ProcessingIdentity.recordingFingerprint([second, chunk]))
        chunk.sha256 = "bbb"; XCTAssertNotEqual(original, ProcessingIdentity.recordingFingerprint([chunk]))
        chunk.sha256 = "aaa"; chunk.startTime = 0.01; XCTAssertNotEqual(original, ProcessingIdentity.recordingFingerprint([chunk]))
    }
    private func snapshot(_ id: String, start: Double, owner: Double, segments: [TranscriptSegment]) -> TranscriptionSnapshot {
        TranscriptionSnapshot(window: ProcessingWindow(track: .remote, epochID: "e", start: start, duration: 30, windowID: id, provisional: false, relativePath: "derived/test.wav", ownershipStart: owner, ownershipEnd: owner + 28), segments: segments)
    }
    private func segment(_ id: String, window: String, start: Double, end: Double, text: String) -> TranscriptSegment {
        TranscriptSegment(id: id, meetingID: "m", windowID: window, track: .remote, startTime: start, endTime: end, text: text, speakerID: nil, isUncertain: false, isProvisional: false, isEdited: false)
    }
}
