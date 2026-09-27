import Foundation
import XCTest
@testable import EchoCore

final class LongMeetingFixtureTests: XCTestCase {
    func testTwoHourFixtureHasTenThousandOverlappingPassagesAndReviewHistory() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ECHO_TEST_ROOT"] ?? FileManager.default.currentDirectoryPath + "/tmp/tests")
            .appendingPathComponent("long-meeting-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(paths: AppPaths(root: root))

        let id = try SyntheticLongMeetingFixture.seed(store: store, hours: 2, passageCount: 10_000)

        let meeting = try XCTUnwrap(store.meeting(id: id))
        XCTAssertEqual(meeting.endedAt?.timeIntervalSince(meeting.startedAt), 7_200)
        let fullReadStarted = ProcessInfo.processInfo.systemUptime
        let segments = try store.segments(meetingID: id)
        let fullReadMilliseconds = (ProcessInfo.processInfo.systemUptime - fullReadStarted) * 1_000
        let pageReadStarted = ProcessInfo.processInfo.systemUptime
        let page = try store.transcriptPage(.init(meetingID: id, versionID: "legacy-" + id, anchor: nil, direction: .forward))
        let pageReadMilliseconds = (ProcessInfo.processInfo.systemUptime - pageReadStarted) * 1_000
        print(String(format: "ECHO_PERF fixture=two-hour segments=10000 fullReadMs=%.2f pageReadMs=%.2f pageRows=%d", fullReadMilliseconds, pageReadMilliseconds, page.rows.count))
        XCTAssertEqual(page.rows.count, 200)
        XCTAssertEqual(segments.count, 10_000)
        XCTAssertEqual(segments.first?.startTime, 0)
        XCTAssertEqual(segments[1].startTime, 0)
        XCTAssertEqual(Set(segments.prefix(2).map(\.track)), Set<AudioTrack>([.microphone, .remote]))
        XCTAssertGreaterThan(segments.last?.startTime ?? 0, 7_000)
        XCTAssertEqual(try store.speakers(meetingID: id).count, 2)
        XCTAssertEqual(try store.speakerGroupingRuns(meetingID: id).first?.turns.count, 3)
        XCTAssertEqual(try store.annotations(meetingID: id).count, 2)
        XCTAssertEqual(try store.notes(meetingID: id).count, 1)
        XCTAssertEqual(try store.jobStatusSummary(meetingID: id).queuedCount, 0)
        XCTAssertEqual(try store.transcriptVersions(meetingID: id).count, 1)
        XCTAssertEqual(try store.jobs(meetingID: id).count, 2)
    }

    func testEightHourFixtureCoversEndWithoutAllocatingEightHoursOfAudio() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ECHO_TEST_ROOT"] ?? FileManager.default.currentDirectoryPath + "/tmp/tests")
            .appendingPathComponent("eight-hour-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(paths: AppPaths(root: root))

        let id = try SyntheticLongMeetingFixture.seed(store: store, hours: 8, passageCount: 400)

        let meeting = try XCTUnwrap(store.meeting(id: id))
        XCTAssertEqual(meeting.endedAt?.timeIntervalSince(meeting.startedAt), 28_800)
        XCTAssertGreaterThan(try store.segments(meetingID: id).last?.startTime ?? 0, 28_000)
    }
}

/// A database workload with realistic review metadata and no microphone content or audio files.
private enum SyntheticLongMeetingFixture {
    static func seed(store: MeetingStore, hours: Int, passageCount: Int) throws -> String {
        precondition(hours > 0 && passageCount >= 2 && passageCount.isMultiple(of: 2))
        let meetingID = "fixture-\(UUID().uuidString)"
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let duration = Double(hours * 3_600)
        try store.createMeeting(Meeting(
            id: meetingID, title: "Synthetic long meeting", startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(duration), state: .ready,
            language: "en", sourceName: "Fixture application",
            usesEchoCancellation: false, transcriptRevision: 0
        ))

        let speakers = [
            Speaker(id: "speaker-remote", meetingID: meetingID, label: "Speaker 1", isVerified: false),
            Speaker(id: "speaker-mic", meetingID: meetingID, label: "Speaker 2", isVerified: false),
        ]
        for speaker in speakers { try store.upsertSpeaker(speaker) }

        let pairCount = passageCount / 2
        let step = (duration - 1) / Double(pairCount)
        var firstPair: [TranscriptSegment] = []
        for batchStart in stride(from: 0, to: passageCount, by: 200) {
            let batchEnd = min(batchStart + 200, passageCount)
            let windowID = "fixture-window-\(batchStart / 200)"
            let batch: [TranscriptSegment] = (batchStart..<batchEnd).map { index in
                let start = Double(index / 2) * step
                let track: AudioTrack = index.isMultiple(of: 2) ? .remote : .microphone
                let text = index.isMultiple(of: 5)
                    ? "Synthetic passage \(index) with several timed words and a longer line for layout."
                    : "Synthetic passage \(index) for transcript review."
                let firstWord = TranscriptWord(
                    id: "word-\(index)", text: "Synthetic", location: 0, length: 9,
                    start: start, end: start + 0.3, source: .nativeWord
                )
                return TranscriptSegment(
                    id: String(format: "segment-%05d", index), meetingID: meetingID,
                    windowID: windowID, track: track, startTime: start,
                    endTime: min(duration, start + 0.9), text: text,
                    speakerID: track == .remote ? speakers[0].id : speakers[1].id,
                    isUncertain: false, isProvisional: false, isEdited: index == 4,
                    words: [firstWord]
                )
            }
            if firstPair.isEmpty { firstPair = Array(batch.prefix(2)) }
            try store.replaceSegments(meetingID: meetingID, windowID: windowID, segments: batch, isFinal: true)
        }

        let version = TranscriptVersion(
            id: "fixture-version", meetingID: meetingID, status: .building,
            configuration: nil, audioFingerprint: "synthetic"
        )
        try store.saveTranscriptVersion(version)
        try store.saveVersionWindow(versionID: version.id, windowID: "history-window", segments: firstPair.map { segment in
            var copy = segment
            copy.windowID = "history-window"
            return copy
        })
        var readyVersion = version
        readyVersion.status = .ready
        try store.saveTranscriptVersion(readyVersion)

        try store.saveSpeakerGrouping(SpeakerGroupingRun(
            id: "fixture-grouping", meetingID: meetingID,
            transcriptVersionID: "legacy-" + meetingID, track: .remote,
            model: nil, audioFingerprint: "synthetic", partial: false,
            turns: [
                SpeakerTurn(start: 0, end: min(duration, 20), speakerID: speakers[0].id),
                SpeakerTurn(start: 10, end: min(duration, 15), speakerID: speakers[1].id),
                SpeakerTurn(start: 20, end: duration, speakerID: speakers[0].id),
            ]
        ))

        try store.saveAnnotation(TranscriptAnnotation(
            meetingID: meetingID, kind: .bookmark, segmentID: firstPair[0].id,
            startTime: 0, label: "Opening"
        ))
        try store.saveAnnotation(TranscriptAnnotation(
            meetingID: meetingID, kind: .highlight,
            transcriptVersionID: "legacy-" + meetingID, segmentID: firstPair[1].id,
            location: 0, length: 9, quote: "Synthetic", track: .microphone,
            startTime: 0, endTime: firstPair[1].endTime
        ))
        try store.saveNotes(MeetingNotes(
            id: "fixture-notes", meetingID: meetingID, createdAt: startedAt,
            transcriptRevision: 0,
            summary: [NoteItem(id: "summary", text: "Synthetic summary", evidenceIDs: [firstPair[0].id])],
            decisions: [], actionItems: [], isEdited: false, isPartial: false
        ))
        for index in 0..<2 {
            try store.enqueue(ProcessingJob(
                id: "fixture-job-\(index)", meetingID: meetingID,
                kind: index == 0 ? .transcribe : .diarize,
                status: .completed, payload: "{}", attempts: 1,
                error: nil, createdAt: startedAt.addingTimeInterval(Double(index))
            ))
        }
        return meetingID
    }
}
