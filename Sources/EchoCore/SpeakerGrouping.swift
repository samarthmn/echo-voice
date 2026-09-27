import Foundation
import GRDB

public struct SpeakerTurn: Codable, Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var speakerID: String
    public init(start: Double, end: Double, speakerID: String) { self.start = start; self.end = end; self.speakerID = speakerID }
}

public struct SpeakerGroupingRun: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var meetingID: String
    public var transcriptVersionID: String
    public var track: AudioTrack
    public var model: ModelSelection?
    public var audioFingerprint: String
    public var algorithmVersion: String
    public var createdAt: Date
    public var partial: Bool
    public var turns: [SpeakerTurn]
    public init(id: String, meetingID: String, transcriptVersionID: String, track: AudioTrack, model: ModelSelection?, audioFingerprint: String, partial: Bool, turns: [SpeakerTurn]) {
        self.id = id; self.meetingID = meetingID; self.transcriptVersionID = transcriptVersionID; self.track = track; self.model = model
        self.audioFingerprint = audioFingerprint; self.partial = partial; self.turns = turns; createdAt = Date(); algorithmVersion = "track-grouping-v1"
    }
}

extension MeetingStore {
    public func saveSpeakerGrouping(_ run: SpeakerGroupingRun, assignments: [String: String] = [:], reapply: Bool = false) throws {
        guard run.turns.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start }),
              run.track == .remote || run.track == .microphone else { throw EchoCoreError.invalidValue("speaker turns") }
        try database.write { db in
            guard let meeting = try Row.fetchOne(db, sql: "SELECT recording_mode FROM meetings WHERE id=?", arguments: [run.meetingID]),
                  (RecordingMode(rawValue: meeting["recording_mode"]) ?? .online).groupingTrack == run.track else { throw EchoCoreError.invalidValue("grouping source does not match meeting mode") }
            let active = try String.fetchOne(db, sql: "SELECT active_version FROM meeting_configuration WHERE meeting_id=?", arguments: [run.meetingID]) ?? "legacy-" + run.meetingID
            guard active == run.transcriptVersionID else { throw EchoCoreError.invalidValue("grouping transcript is no longer active") }
            let prior = try Data.fetchOne(db, sql: "SELECT payload FROM speaker_grouping_runs WHERE id=?", arguments: [run.id])
            if prior != nil && !reapply { return }
            if let prior, try decode(SpeakerGroupingRun.self, from: prior) != run { throw EchoCoreError.invalidValue("grouping run changed") }
            var changed = false
            for (segmentID, speakerID) in assignments {
                guard run.turns.contains(where: { $0.speakerID == speakerID }) else { throw EchoCoreError.invalidValue("unknown grouping speaker") }
                // Change attribution only. Never rewrite corrected text, word timing, or recognition confidence.
                let previousSpeaker = try String.fetchOne(db, sql: "SELECT speaker_id FROM transcript_segments WHERE meeting_id=? AND id=? AND track=?", arguments: [run.meetingID, segmentID, run.track.rawValue])
                try db.execute(sql: "UPDATE transcript_segments SET speaker_id=? WHERE meeting_id=? AND id=? AND track=?", arguments: [speakerID, run.meetingID, segmentID, run.track.rawValue])
                guard db.changesCount == 1 else { throw EchoCoreError.invalidValue("grouping segment is missing") }
                changed = changed || previousSpeaker != speakerID
            }
            if prior == nil {
            try db.execute(sql: "INSERT INTO speaker_grouping_runs(id,meeting_id,version_id,created_at,payload) VALUES(?,?,?,?,?)", arguments: [run.id, run.meetingID, run.transcriptVersionID, run.createdAt.timeIntervalSince1970, try encode(run)])
            }
            if prior == nil || changed {
            try db.execute(sql: "UPDATE meetings SET transcript_revision=transcript_revision+1 WHERE id=?", arguments: [run.meetingID])
            }
        }
    }
    public func speakerGroupingRuns(meetingID: String) throws -> [SpeakerGroupingRun] {
        try database.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM speaker_grouping_runs WHERE meeting_id=? ORDER BY created_at DESC,id", arguments: [meetingID]).map { try decode(SpeakerGroupingRun.self, from: $0) }
        }
    }
}

/// A display projection: source transcript IDs, text and evidence anchors remain unchanged.
public struct SpeakerAttributionSpan: Sendable, Equatable {
    public var range: NSRange
    public var start: Double
    public var speakerIDs: [String]
    public var uncertain: Bool
}

public struct SpeakerTurnIndex: Sendable {
    private let run: SpeakerGroupingRun
    private let ordered: [SpeakerTurn]
    private let maximumEnds: [Double]

    public init(run: SpeakerGroupingRun) {
        self.run = run
        ordered = run.turns.sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        var maximum = -Double.infinity
        maximumEnds = ordered.map { maximum = max(maximum, $0.end); return maximum }
    }

    private func matching(at time: Double) -> [SpeakerTurn] {
        var low = 0, high = ordered.count
        while low < high {
            let middle = (low + high) / 2
            if ordered[middle].start <= time { low = middle + 1 } else { high = middle }
        }
        var index = low - 1
        var result: [SpeakerTurn] = []
        while index >= 0 && maximumEnds[index] > time {
            if ordered[index].end > time { result.append(ordered[index]) }
            index -= 1
        }
        return result
    }

    public func spans(segment: TranscriptSegment) -> [SpeakerAttributionSpan] {
        guard segment.track == run.track, segment.meetingID == run.meetingID else { return [] }
        let words = (segment.words ?? []).filter { $0.valid(in: segment.text, start: segment.startTime, end: segment.endTime) && $0.source != .passage }
        var spans: [SpeakerAttributionSpan] = []
        var previousEnd = 0
        var previousTime = -Double.infinity
        for word in words {
            guard word.location >= previousEnd, word.start >= previousTime else { return [] }
            let matches = matching(at: word.start)
            let speakers = Array(Set(matches.map(\.speakerID))).sorted()
            let uncertain = run.partial || speakers.count != 1 || word.source == .tokenEmission || (word.end.map { end in matches.contains { $0.end < end } } ?? true)
            if let last = spans.last, last.speakerIDs == speakers, last.uncertain == uncertain {
                spans[spans.count - 1].range.length = NSMaxRange(word.range) - last.range.location
            } else {
                spans.append(.init(range: word.range, start: word.start, speakerIDs: speakers, uncertain: uncertain))
            }
            previousEnd = NSMaxRange(word.range); previousTime = word.start
        }
        return spans
    }
}

public enum SpeakerAttribution {
    public static func spans(segment: TranscriptSegment, run: SpeakerGroupingRun) -> [SpeakerAttributionSpan] {
        SpeakerTurnIndex(run: run).spans(segment: segment)
    }
}
