import Foundation
import GRDB

public struct RedactionPreview: Sendable, Equatable {
    public let meetingID: String
    public let segmentID: String
    public let transcriptRevision: Int
    public let audioRevision: Int
    public let start: Double
    public let end: Double
    public let affectedTracks: Set<AudioTrack>
    public let activePassages: Int
    public let historicalPassages: Int
    public let annotations: Int
    public let noteItems: Int
    public let affectedPassageExcerpts: [String]
    public let whollyRemovedOverlappingPassages: Int
}

private enum RedactionText {
    static func retained(_ segment: TranscriptSegment, start: Double, end: Double,
                         operationID: String) -> [TranscriptSegment] {
        guard segment.startTime < start || segment.endTime > end,
              let words = segment.words, !words.isEmpty else { return [] }
        let source = segment.text as NSString
        guard words.allSatisfy({ word in
            word.source == .nativeWord && !word.derived && word.end != nil &&
            word.valid(in: segment.text, start: segment.startTime, end: segment.endTime) &&
            source.substring(with: word.range) == word.text
        }) else { return [] }
        let ordered = words.sorted { $0.start < $1.start }
        guard zip(ordered, ordered.dropFirst()).allSatisfy({ pair in
            pair.0.end! <= pair.1.start && pair.0.location + pair.0.length <= pair.1.location
        }) else {
            return []
        }
        func piece(_ label: String, _ retainedWords: [TranscriptWord]) -> TranscriptSegment? {
            guard let first = retainedWords.first, let last = retainedWords.last, let lastEnd = last.end else { return nil }
            var text = ""
            var adjusted: [TranscriptWord] = []
            for word in retainedWords {
                if !text.isEmpty { text += " " }
                var copy = word
                copy.location = (text as NSString).length
                copy.length = (word.text as NSString).length
                adjusted.append(copy)
                text += word.text
            }
            var result = segment
            result.id = "\(segment.id)-redacted-\(operationID)-\(label)"
            result.startTime = first.start
            result.endTime = lastEnd
            result.text = text
            result.words = adjusted
            result.recognitionEvidence = nil
            return result
        }
        return [piece("before", ordered.filter { $0.end! <= start }),
                piece("after", ordered.filter { $0.start >= end })].compactMap { $0 }
    }
}

/// Ownership of completed recognition before an audio revision changed its job IDs.
/// The original window ID remains the source of retained human corrections.
public struct CompletedSpeechWindow: Codable, Sendable, Equatable {
    public let windowID: String
    public let track: AudioTrack
    public let epochID: String
    public let ownershipStart: Double
    public let ownershipEnd: Double

    public init(windowID: String, track: AudioTrack, epochID: String,
                ownershipStart: Double, ownershipEnd: Double) {
        self.windowID = windowID; self.track = track; self.epochID = epochID
        self.ownershipStart = ownershipStart; self.ownershipEnd = ownershipEnd
    }
}

public struct AudioRedaction: Codable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable { case intent, staged, published, completed }
    public var id: String
    public var meetingID: String
    public var start: Double
    public var end: Double
    public var oldChunks: [CapturedChunk]
    public var newChunks: [CapturedChunk]
    public var epochSplits: [String: String]
    public var preserveExistingTranscript: Bool
    public var completedSpeechWindows: [CompletedSpeechWindow]
    public var state: State

    public init(id: String = UUID().uuidString, meetingID: String, start: Double, end: Double,
                oldChunks: [CapturedChunk], newChunks: [CapturedChunk] = [],
                epochSplits: [String: String] = [:], preserveExistingTranscript: Bool = false,
                completedSpeechWindows: [CompletedSpeechWindow] = [],
                state: State = .intent) {
        self.id = id; self.meetingID = meetingID; self.start = start; self.end = end
        self.oldChunks = oldChunks; self.newChunks = newChunks; self.epochSplits = epochSplits
        self.preserveExistingTranscript = preserveExistingTranscript
        self.completedSpeechWindows = completedSpeechWindows; self.state = state
    }

    private enum CodingKeys: String, CodingKey { case id, meetingID, start, end, oldChunks, newChunks, epochSplits, preserveExistingTranscript, completedSpeechWindows, state }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        meetingID = try values.decode(String.self, forKey: .meetingID)
        start = try values.decode(Double.self, forKey: .start)
        end = try values.decode(Double.self, forKey: .end)
        oldChunks = try values.decode([CapturedChunk].self, forKey: .oldChunks)
        newChunks = try values.decode([CapturedChunk].self, forKey: .newChunks)
        epochSplits = try values.decodeIfPresent([String: String].self, forKey: .epochSplits) ?? [:]
        preserveExistingTranscript = try values.decodeIfPresent(Bool.self, forKey: .preserveExistingTranscript) ?? false
        completedSpeechWindows = try values.decodeIfPresent([CompletedSpeechWindow].self, forKey: .completedSpeechWindows) ?? []
        state = try values.decode(State.self, forKey: .state)
    }
}

extension MeetingStore {
    func ensureOutsideRedactions(_ db: Database, meetingID: String,
                                 segments: [TranscriptSegment]) throws {
        guard !segments.isEmpty else { return }
        let intervals: [(Double, Double)] = try Row.fetchAll(db, sql: "SELECT start_time,end_time FROM audio_redactions WHERE meeting_id=?",
                                                            arguments: [meetingID]).map { ($0["start_time"], $0["end_time"]) }
        guard !intervals.isEmpty else { return }
        if segments.contains(where: { segment in
            intervals.contains { segment.startTime < $0.1 && segment.endTime > $0.0 }
        }) {
            throw EchoCoreError.invalidValue("passage overlaps permanently deleted audio")
        }
    }

    public func redactionPreview(meetingID: String, segmentID: String) throws -> RedactionPreview {
        let audioDirectory = paths.meetingDirectory(meetingID).appendingPathComponent("audio", isDirectory: true)
        if FileManager.default.fileExists(atPath: audioDirectory.path) {
            let entries = try FileManager.default.contentsOfDirectory(at: audioDirectory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if entries.contains(where: {
                $0.lastPathComponent.hasSuffix(".partial.caf") ||
                $0.lastPathComponent.hasSuffix(".caf.intent.json") ||
                $0.lastPathComponent.hasSuffix(".caf.chunk.json")
            }) {
                throw EchoCoreError.invalidValue("unfinished capture audio must be recovered or repaired before deleting a passage")
            }
        }
        let activeVersion = try activeTranscriptVersion(meetingID: meetingID)
        guard let meeting = try meeting(id: meetingID),
              ![.recording, .paused, .interrupted].contains(meeting.state),
              let target = try segment(meetingID: meetingID, versionID: activeVersion, segmentID: segmentID),
              target.endTime > target.startTime else { throw EchoCoreError.invalidValue("finish recording before deleting a passage") }
        let start = target.startTime
        let end = target.endTime
        let allSegments: [TranscriptSegment] = try segments(meetingID: meetingID)
        let overlapping: [TranscriptSegment] = allSegments.filter { $0.startTime < end && $0.endTime > start }
        var historical = 0
        var affectedIDs = Set(overlapping.map { $0.id })
        for version in try transcriptVersions(meetingID: meetingID) {
            let history = try versionSegments(versionID: version.id).filter { $0.startTime < end && $0.endTime > start }
            historical += history.count
            affectedIDs.formUnion(history.map { $0.id })
        }
        let savedAnnotations: [TranscriptAnnotation] = try annotations(meetingID: meetingID)
        let annotationCount = savedAnnotations.filter { item in
            let inTime = item.startTime < end && (item.endTime ?? item.startTime + 0.001) > start
            return inTime || (item.segmentID.map { affectedIDs.contains($0) } ?? false)
        }.count
        let savedNotes: [MeetingNotes] = try notes(meetingID: meetingID)
        let noteItems = savedNotes.reduce(0) { count, note in
            let items = note.summary + note.decisions + note.actionItems
            return count + items.filter { !Set($0.evidenceIDs).isDisjoint(with: affectedIDs) }.count
        }
        let captured: [CapturedChunk] = try chunks(meetingID: meetingID)
        let tracks = Set(captured.filter { $0.startTime < end && $0.startTime + $0.duration > start }.map { $0.track })
        let excerpts = overlapping.prefix(3).map { String($0.text.prefix(120)) }
        let whollyRemoved = overlapping.filter {
            RedactionText.retained($0, start: start, end: end, operationID: "preview").isEmpty &&
            ($0.startTime < start || $0.endTime > end)
        }.count
        return RedactionPreview(meetingID: meetingID, segmentID: segmentID,
                                transcriptRevision: meeting.transcriptRevision,
                                audioRevision: try audioRevision(meetingID: meetingID), start: start, end: end,
                                affectedTracks: tracks, activePassages: overlapping.count,
                                historicalPassages: historical, annotations: annotationCount, noteItems: noteItems,
                                affectedPassageExcerpts: excerpts, whollyRemovedOverlappingPassages: whollyRemoved)
    }

    public func pendingRedactions() throws -> [AudioRedaction] {
        try database.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM audio_redactions WHERE state!='completed' ORDER BY rowid")
                .map { try decode(AudioRedaction.self, from: $0) }
        }
    }

    public func redactions(meetingID: String) throws -> [AudioRedaction] {
        try database.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM audio_redactions WHERE meeting_id=? AND state='completed' ORDER BY start_time,id", arguments: [meetingID])
                .map { try decode(AudioRedaction.self, from: $0) }
        }
    }

    public func canReuseTranscriptAfterRedaction(meetingID: String) throws -> Bool {
        let completed = try redactions(meetingID: meetingID)
        return !completed.isEmpty && completed.allSatisfy(\.preserveExistingTranscript)
    }

    public func audioRevision(meetingID: String) throws -> Int {
        try database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM audio_redactions WHERE meeting_id=? AND state IN ('published','completed')", arguments: [meetingID]) ?? 0
        }
    }

    public func saveRedactionIntent(_ redaction: AudioRedaction) throws {
        guard AppPaths.isSafeIdentifier(redaction.id), AppPaths.isSafeIdentifier(redaction.meetingID),
              redaction.start.isFinite, redaction.end.isFinite, redaction.start >= 0,
              redaction.end > redaction.start, redaction.state == .intent else {
            throw EchoCoreError.invalidValue("audio redaction")
        }
        try database.write { db in
            guard try Int.fetchOne(db, sql: "SELECT 1 FROM audio_redactions WHERE meeting_id=? AND state!='completed'", arguments: [redaction.meetingID]) == nil else {
                throw EchoCoreError.invalidValue("another passage deletion is still in progress")
            }
            try db.execute(sql: "INSERT INTO audio_redactions(id,meeting_id,start_time,end_time,state,payload) VALUES (?,?,?,?,?,?)",
                           arguments: [redaction.id, redaction.meetingID, redaction.start, redaction.end,
                                       redaction.state.rawValue, try encode(redaction)])
        }
    }

    public func saveStagedRedaction(_ redaction: AudioRedaction) throws {
        guard redaction.state == .staged else { throw EchoCoreError.invalidValue("redaction stage") }
        try database.write { db in
            let previous: String? = try String.fetchOne(db, sql: "SELECT state FROM audio_redactions WHERE id=?", arguments: [redaction.id])
            guard previous == AudioRedaction.State.intent.rawValue || previous == AudioRedaction.State.staged.rawValue else {
                throw EchoCoreError.invalidValue("redaction is no longer staging")
            }
            try db.execute(sql: "UPDATE audio_redactions SET state='staged',payload=? WHERE id=?",
                           arguments: [try encode(redaction), redaction.id])
        }
    }

    public func publishRedaction(_ redaction: AudioRedaction) throws {
        guard redaction.state == .staged else { throw EchoCoreError.invalidValue("redaction publication") }
        for chunk in redaction.newChunks {
            let file = try validatedAssetURL(meetingID: chunk.meetingID, relativePath: chunk.relativePath)
            guard try Self.sha256(file).caseInsensitiveCompare(chunk.sha256) == .orderedSame else {
                throw EchoCoreError.checksumMismatch(chunk.relativePath)
            }
        }
        try database.write { db in
            let state: String? = try String.fetchOne(db, sql: "SELECT state FROM audio_redactions WHERE id=?", arguments: [redaction.id])
            if state == AudioRedaction.State.published.rawValue || state == AudioRedaction.State.completed.rawValue { return }
            guard state == AudioRedaction.State.staged.rawValue else { throw EchoCoreError.invalidValue("redaction is not staged") }
            for old in redaction.oldChunks {
                guard try Int.fetchOne(db, sql: "SELECT 1 FROM chunks WHERE meeting_id=? AND id=?", arguments: [old.meetingID, old.id]) != nil else {
                    throw EchoCoreError.invalidValue("recording changed during passage deletion")
                }
            }
            for old in redaction.oldChunks {
                try db.execute(sql: "DELETE FROM audio_representations WHERE meeting_id=? AND chunk_id=?", arguments: [old.meetingID, old.id])
                try db.execute(sql: "DELETE FROM chunks WHERE meeting_id=? AND id=?", arguments: [old.meetingID, old.id])
            }
            for (oldEpoch, newEpoch) in redaction.epochSplits {
                try db.execute(sql: "UPDATE chunks SET epoch_id=? WHERE meeting_id=? AND track=? AND epoch_id=? AND start_time>=?",
                               arguments: [newEpoch, redaction.meetingID, AudioTrack.microphone.rawValue,
                                           oldEpoch, redaction.end])
                if let payload = try Data.fetchOne(db, sql: "SELECT payload FROM microphone_processing_epochs WHERE meeting_id=? AND epoch_id=?",
                                                   arguments: [redaction.meetingID, oldEpoch]) {
                    var epoch = try decode(MicrophoneProcessingEpoch.self, from: payload)
                    epoch.epochID = newEpoch
                    epoch.startTime = redaction.end
                    try db.execute(sql: "INSERT INTO microphone_processing_epochs(meeting_id,epoch_id,start_time,acoustic_mode,payload) VALUES (?,?,?,?,?)",
                                   arguments: [redaction.meetingID, newEpoch, epoch.startTime,
                                               epoch.acousticMode.rawValue, try encode(epoch)])
                }
            }
            for chunk in redaction.newChunks {
                try db.execute(sql: """
                    INSERT INTO chunks(meeting_id,id,epoch_id,track,relative_path,start_time,duration,sample_rate,frame_count,sha256)
                    VALUES (?,?,?,?,?,?,?,?,?,?)
                    """, arguments: [chunk.meetingID, chunk.id, chunk.epochID, chunk.track.rawValue,
                                       chunk.relativePath, chunk.startTime, chunk.duration, chunk.sampleRate,
                                       chunk.frameCount, chunk.sha256])
            }
            var removedSegmentIDs = Set<String>()
            for row in try Row.fetchAll(db, sql: "SELECT * FROM transcript_segments WHERE meeting_id=?", arguments: [redaction.meetingID]) {
                var segment = decodeSegment(row)
                if segment.recognitionEvidence?.mayContainAudio(start: redaction.start, end: redaction.end) == true {
                    segment.recognitionEvidence = nil
                    try replaceFTSRow(db, segment: segment)
                }
                guard segment.startTime < redaction.end && segment.endTime > redaction.start else { continue }
                let id = segment.id
                removedSegmentIDs.insert(id)
                try db.execute(sql: "DELETE FROM segment_fts WHERE meeting_id=? AND segment_id=?", arguments: [redaction.meetingID, id])
                try db.execute(sql: "DELETE FROM transcript_segments WHERE meeting_id=? AND id=?", arguments: [redaction.meetingID, id])
                for piece in RedactionText.retained(segment, start: redaction.start, end: redaction.end,
                                                   operationID: redaction.id) {
                    try db.execute(sql: """
                        INSERT INTO transcript_segments(meeting_id,id,window_id,track,start_time,end_time,text,speaker_id,is_uncertain,is_provisional,is_edited)
                        VALUES (?,?,?,?,?,?,?,?,?,?,?)
                        """, arguments: segmentArguments(piece))
                    try replaceFTSRow(db, segment: piece)
                }
            }
            // Preview rows are tied to obsolete audio-window IDs. The final
            // scheduler will rebuild their audio under the new revision; do
            // not leave stale machine previews next to that final text.
            for row in try Row.fetchAll(db, sql: "SELECT id,is_edited FROM transcript_segments WHERE meeting_id=? AND is_provisional=1",
                                        arguments: [redaction.meetingID]) {
                let id: String = row["id"]
                let edited: Bool = row["is_edited"]
                if edited {
                    try db.execute(sql: "UPDATE transcript_segments SET is_provisional=0 WHERE meeting_id=? AND id=?",
                                   arguments: [redaction.meetingID, id])
                } else {
                    try db.execute(sql: "DELETE FROM segment_fts WHERE meeting_id=? AND segment_id=?",
                                   arguments: [redaction.meetingID, id])
                    try db.execute(sql: "DELETE FROM transcript_segments WHERE meeting_id=? AND id=?",
                                   arguments: [redaction.meetingID, id])
                }
            }
            for row in try Row.fetchAll(db, sql: """
                SELECT s.version_id,s.id,s.payload FROM version_segments s
                JOIN transcript_versions v ON v.id=s.version_id WHERE v.meeting_id=?
                """, arguments: [redaction.meetingID]) {
                var segment = try decode(TranscriptSegment.self, from: row["payload"])
                if segment.recognitionEvidence?.mayContainAudio(start: redaction.start, end: redaction.end) == true {
                    segment.recognitionEvidence = nil
                    try db.execute(sql: "UPDATE version_segments SET payload=? WHERE version_id=? AND id=?",
                                   arguments: [try encode(segment), row["version_id"] as String, segment.id])
                }
                guard segment.startTime < redaction.end && segment.endTime > redaction.start else { continue }
                removedSegmentIDs.insert(segment.id)
                try db.execute(sql: "DELETE FROM version_segments WHERE version_id=? AND id=?",
                               arguments: [row["version_id"] as String, row["id"] as String])
                for piece in RedactionText.retained(segment, start: redaction.start, end: redaction.end,
                                                   operationID: redaction.id) {
                    try db.execute(sql: "INSERT INTO version_segments(version_id,id,window_id,start_time,payload) VALUES (?,?,?,?,?)",
                                   arguments: [row["version_id"] as String, piece.id, piece.windowID,
                                               piece.startTime, try encode(piece)])
                }
            }
            for row in try Row.fetchAll(db, sql: "SELECT id,payload FROM transcript_annotations WHERE meeting_id=?", arguments: [redaction.meetingID]) {
                let item = try decode(TranscriptAnnotation.self, from: row["payload"])
                if item.startTime < redaction.end && (item.endTime ?? item.startTime + 0.001) > redaction.start
                    || item.segmentID.map({ removedSegmentIDs.contains($0) }) == true {
                    try db.execute(sql: "DELETE FROM transcript_annotations WHERE id=?", arguments: [item.id])
                }
            }
            for row in try Row.fetchAll(db, sql: "SELECT * FROM meeting_notes WHERE meeting_id=?", arguments: [redaction.meetingID]) {
                let notes = try decodeNotes(row)
                func retained(_ items: [NoteItem]) -> [NoteItem] {
                    items.filter { Set($0.evidenceIDs).isDisjoint(with: removedSegmentIDs) }
                }
                let summary = retained(notes.summary)
                let decisions = retained(notes.decisions)
                let actions = retained(notes.actionItems)
                guard summary.count != notes.summary.count || decisions.count != notes.decisions.count
                        || actions.count != notes.actionItems.count else { continue }
                try db.execute(sql: "UPDATE meeting_notes SET summary_json=?,decisions_json=?,action_items_json=?,is_partial=1 WHERE meeting_id=? AND id=?",
                               arguments: [try encode(summary), try encode(decisions), try encode(actions),
                                           redaction.meetingID, notes.id])
            }
            for row in try Row.fetchAll(db, sql: "SELECT id,payload FROM speaker_grouping_runs WHERE meeting_id=?", arguments: [redaction.meetingID]) {
                var run = try decode(SpeakerGroupingRun.self, from: row["payload"])
                run.turns = run.turns.flatMap { turn -> [SpeakerTurn] in
                    guard turn.start < redaction.end && turn.end > redaction.start else { return [turn] }
                    var pieces: [SpeakerTurn] = []
                    if turn.start < redaction.start { pieces.append(.init(start: turn.start, end: redaction.start, speakerID: turn.speakerID)) }
                    if turn.end > redaction.end { pieces.append(.init(start: redaction.end, end: turn.end, speakerID: turn.speakerID)) }
                    return pieces
                }
                try db.execute(sql: "UPDATE speaker_grouping_runs SET payload=? WHERE id=?", arguments: [try encode(run), run.id])
            }
            try db.execute(sql: "DELETE FROM processing_jobs WHERE meeting_id=?", arguments: [redaction.meetingID])
            try db.execute(sql: "INSERT INTO capture_gaps(meeting_id,id,start_time,end_time,reason) VALUES (?,?,?,?,?)",
                           arguments: [redaction.meetingID, redaction.id, redaction.start, redaction.end,
                                       "Passage and audio permanently deleted"])
            try db.execute(sql: "UPDATE meetings SET transcript_revision=transcript_revision+1 WHERE id=?", arguments: [redaction.meetingID])
            var published = redaction; published.state = .published
            try db.execute(sql: "UPDATE audio_redactions SET state='published',payload=? WHERE id=?",
                           arguments: [try encode(published), redaction.id])
        }
    }

    public func completeRedaction(_ redaction: AudioRedaction) throws {
        var completed = redaction; completed.state = .completed
        try database.write { db in
            try db.execute(sql: "UPDATE audio_redactions SET state='completed',payload=? WHERE id=? AND state='published'",
                           arguments: [try encode(completed), redaction.id])
        }
    }
}
