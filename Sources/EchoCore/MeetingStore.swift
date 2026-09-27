import Foundation
import CryptoKit
import Darwin
import GRDB

public struct MeetingAssetRecoveryIssue: Sendable, Equatable {
    public let meetingID: String
    public let message: String
}

public final class MeetingStore: @unchecked Sendable {
    public let paths: AppPaths
    let database: DatabaseQueue
    public let audioAssets: AudioAssetStore
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let deletionCheckpoint: @Sendable (URL, URL) throws -> Void
    private let purgeCheckpoint: @Sendable (URL) throws -> Void
    private let exportSnapshotCheckpoint: @Sendable () -> Void
    private let deletionRecoveryLock = NSLock()
    private let deletionIssueLock = NSLock()
    private var deletionIssues: [String: MeetingAssetRecoveryIssue] = [:]

    public convenience init(paths: AppPaths) throws {
        try self.init(paths: paths, deletionCheckpoint: { _, _ in }, purgeCheckpoint: { _ in })
    }

    /// Opens the database and library shell before potentially lengthy
    /// per-meeting sidecar verification. Call `recoverMeetingAssets()` next.
    public convenience init(paths: AppPaths, deferAssetRecovery: Bool) throws {
        try self.init(paths: paths, deletionCheckpoint: { _, _ in }, purgeCheckpoint: { _ in },
                      deferAssetRecovery: deferAssetRecovery)
    }

    convenience init(
        paths: AppPaths,
        deletionCheckpoint: @escaping @Sendable (URL, URL) throws -> Void
    ) throws {
        try self.init(paths: paths, deletionCheckpoint: deletionCheckpoint, purgeCheckpoint: { _ in })
    }

    init(
        paths: AppPaths,
        deletionCheckpoint: @escaping @Sendable (URL, URL) throws -> Void,
        purgeCheckpoint: @escaping @Sendable (URL) throws -> Void,
        exportSnapshotCheckpoint: @escaping @Sendable () -> Void = {},
        deferAssetRecovery: Bool = false
    ) throws {
        self.paths = paths
        encoder = JSONEncoder()
        decoder = JSONDecoder()
        self.deletionCheckpoint = deletionCheckpoint
        self.purgeCheckpoint = purgeCheckpoint
        self.exportSnapshotCheckpoint = exportSnapshotCheckpoint

        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try Self.ensureManagedDirectory(paths.meetingsURL, within: paths.root)
        try Self.ensureManagedDirectory(paths.runtimeURL, within: paths.root)
        try Self.ensureManagedDirectory(paths.modelsURL, within: paths.root)
        try Self.ensureManagedDirectory(
            paths.root.appendingPathComponent("Deleted Meetings", isDirectory: true),
            within: paths.root
        )

        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        database = try DatabaseQueue(path: paths.databaseURL.path, configuration: configuration)
        audioAssets = AudioAssetStore(paths: paths, database: database)
        try Self.makeMigrator().migrate(database)
        if !deferAssetRecovery { try audioAssets.recoverPublications() }
        _ = try reconcileDeletionTransactions(performRecovery: !deferAssetRecovery)
        if !deferAssetRecovery {
            try reconcileChunkSidecars()
            try reconcileUnfinishedChunkIntents()
        }
    }

    /// Isolates a corrupt sidecar to its owning meeting. The issue remains
    /// recoverable, while other meetings can still be browsed.
    public func recoverMeetingAssets() throws -> [MeetingAssetRecoveryIssue] {
        var issues = try reconcileDeletionTransactions()
        for item in try meetings() {
            if issues.contains(where: { $0.meetingID == item.id }) { continue }
            do {
                try recoverMeetingAsset(meetingID: item.id)
            } catch {
                issues.append(MeetingAssetRecoveryIssue(meetingID: item.id,
                                                       message: error.localizedDescription))
            }
        }
        return issues
    }

    public func recoverMeetingAsset(meetingID: String) throws {
        if deletionRecoveryIssues.contains(where: { $0.meetingID == meetingID }) {
            _ = try reconcileDeletionTransactions(onlyMeetingID: meetingID)
        }
        try requireDeletionRecovered(meetingID: meetingID)
        guard try meeting(id: meetingID) != nil else { throw EchoCoreError.meetingNotFound(meetingID) }
        try audioAssets.reconcileDecodedCache(meetingID: meetingID)
        try audioAssets.recoverPublications(onlyMeetingID: meetingID)
        try reconcileChunkSidecars(onlyMeetingID: meetingID)
        try reconcileUnfinishedChunkIntents(onlyMeetingID: meetingID)
    }

    public func createMeeting(_ meeting: Meeting) throws {
        try requireDeletionRecovered(meetingID: meeting.id)
        try validate(meeting)
        let directory = paths.meetingDirectory(meeting.id)
        try ensureSafeMeetingDirectory(directory, meetingID: meeting.id)
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO meetings
                        (id, title, started_at, ended_at, state, language, source_name,
                         uses_echo_cancellation, transcript_revision, speech_model, recording_mode)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: meetingArguments(meeting)
            )
        }
    }

    public func meetings() throws -> [Meeting] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM meetings ORDER BY started_at DESC, id ASC")
                .map(decodeMeeting)
        }
    }

    public func meeting(id: String) throws -> Meeting? {
        try database.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM meetings WHERE id = ?", arguments: [id])
                .map(decodeMeeting)
        }
    }

    public func updateMeeting(_ meeting: Meeting) throws {
        try requireDeletionRecovered(meetingID: meeting.id)
        try validate(meeting)
        try database.write { db in
            guard try String.fetchOne(db, sql: "SELECT recording_mode FROM meetings WHERE id = ?", arguments: [meeting.id]) == meeting.recordingMode.rawValue else {
                throw EchoCoreError.invalidIdentifier("Recording mode cannot change after creation")
            }
            try db.execute(
                sql: """
                    UPDATE meetings SET
                        title = ?, started_at = ?, ended_at = ?, state = ?, language = ?,
                        source_name = ?, uses_echo_cancellation = ?
                    WHERE id = ?
                    """,
                arguments: [
                    meeting.title, meeting.startedAt.timeIntervalSince1970,
                    meeting.endedAt?.timeIntervalSince1970, meeting.state.rawValue,
                    meeting.language, meeting.sourceName, meeting.usesEchoCancellation,
                    meeting.id,
                ]
            )
            guard db.changesCount == 1 else { throw EchoCoreError.meetingNotFound(meeting.id) }
        }
    }

    @discardableResult
    public func recoverInterruptedMeetings() throws -> [Meeting] {
        try database.write { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM meetings WHERE state IN (?, ?) ORDER BY started_at ASC, id ASC",
                arguments: [MeetingState.recording.rawValue, MeetingState.paused.rawValue]
            )
            let recovered = rows.map(decodeMeeting).map { meeting -> Meeting in
                var copy = meeting
                copy.state = .interrupted
                return copy
            }
            if !recovered.isEmpty {
                try db.execute(
                    sql: "UPDATE meetings SET state = ? WHERE state IN (?, ?)",
                    arguments: [
                        MeetingState.interrupted.rawValue,
                        MeetingState.recording.rawValue,
                        MeetingState.paused.rawValue,
                    ]
                )
            }
            return recovered
        }
    }

    public func addChunk(_ chunk: CapturedChunk) throws {
        try requireDeletionRecovered(meetingID: chunk.meetingID)
        try validate(chunk)
        _ = try validatedAssetURL(meetingID: chunk.meetingID, relativePath: chunk.relativePath)
        try database.write { db in
            let overlapsDeletedAudio = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM audio_redactions
                              WHERE meeting_id=? AND state IN ('published','completed')
                                AND start_time < ? AND end_time > ?)
                """, arguments: [chunk.meetingID, chunk.startTime + chunk.duration, chunk.startTime]) == true
            guard !overlapsDeletedAudio else {
                throw EchoCoreError.invalidValue("recovered audio overlaps a permanently deleted passage")
            }
            if let existing = try Row.fetchOne(
                db,
                sql: "SELECT * FROM chunks WHERE meeting_id = ? AND id = ?",
                arguments: [chunk.meetingID, chunk.id]
            ) {
                guard decodeChunk(existing) == chunk else {
                    throw EchoCoreError.invalidValue("chunk registration conflict")
                }
                return
            }
            try db.execute(
                sql: """
                    INSERT INTO chunks
                        (meeting_id, id, epoch_id, track, relative_path, start_time,
                         duration, sample_rate, frame_count, sha256)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    chunk.meetingID, chunk.id, chunk.epochID, chunk.track.rawValue,
                    chunk.relativePath, chunk.startTime, chunk.duration, chunk.sampleRate,
                    chunk.frameCount, chunk.sha256,
                ]
            )
        }
        let sidecar = try paths.resolveMeetingAsset(
            meetingID: chunk.meetingID,
            relativePath: chunk.relativePath + ".chunk.json"
        )
        if FileManager.default.fileExists(atPath: sidecar.path) {
            try FileManager.default.removeItem(at: sidecar)
            try Self.syncDirectory(sidecar.deletingLastPathComponent())
        }
        let intentURL = try paths.resolveMeetingAsset(meetingID: chunk.meetingID, relativePath: chunk.relativePath + ".intent.json")
        if FileManager.default.fileExists(atPath: intentURL.path) {
            let gapID = "unfinished-" + chunk.id
            if try gaps(meetingID: chunk.meetingID).contains(where: { $0.id == gapID }) {
                try addGap(CaptureGap(id: gapID, meetingID: chunk.meetingID, startTime: chunk.startTime, endTime: chunk.startTime + chunk.duration, reason: "Recovered finalized raw audio after an interruption; its checksum was verified."))
            }
            try FileManager.default.removeItem(at: intentURL)
            try Self.syncDirectory(intentURL.deletingLastPathComponent())
        }
    }

    public func chunks(meetingID: String, track: AudioTrack? = nil) throws -> [CapturedChunk] {
        try database.read { db in
            let rows: [Row]
            if let track {
                rows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM chunks WHERE meeting_id = ? AND track = ? ORDER BY start_time, id",
                    arguments: [meetingID, track.rawValue]
                )
            } else {
                rows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM chunks WHERE meeting_id = ? ORDER BY start_time, track, id",
                    arguments: [meetingID]
                )
            }
            return rows.map(decodeChunk)
        }
    }

    public struct ChunkCursorRow: Sendable {
        public let rowID: Int64
        public let chunk: CapturedChunk
    }

    public func chunksAdded(meetingID: String, afterRowID: Int64, limit: Int = 512) throws -> [ChunkCursorRow] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT rowid AS capture_order,* FROM chunks WHERE meeting_id=? AND rowid>? ORDER BY rowid LIMIT ?",
                             arguments: [meetingID, afterRowID, max(1, min(limit, 512))])
                .map { ChunkCursorRow(rowID: $0["capture_order"], chunk: decodeChunk($0)) }
        }
    }

    public func chunksOverlapping(meetingID: String, track: AudioTrack,
                                  start: Double, end: Double) throws -> [CapturedChunk] {
        guard start.isFinite, end.isFinite, end > start else { return [] }
        return try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM chunks WHERE meeting_id=? AND track=? AND start_time<?
                  AND start_time+duration>? ORDER BY start_time,id
                """, arguments: [meetingID, track.rawValue, end, start]).map(decodeChunk)
        }
    }

    public func addGap(_ gap: CaptureGap) throws {
        guard AppPaths.isSafeIdentifier(gap.id), AppPaths.isSafeIdentifier(gap.meetingID),
              gap.startTime.isFinite, gap.startTime >= 0,
              gap.endTime.map({ $0.isFinite && $0 >= gap.startTime }) ?? true else {
            throw EchoCoreError.invalidValue("capture gap")
        }
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO capture_gaps (meeting_id, id, start_time, end_time, reason)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(meeting_id, id) DO UPDATE SET
                        start_time = excluded.start_time,
                        end_time = excluded.end_time,
                        reason = excluded.reason
                    """,
                arguments: [gap.meetingID, gap.id, gap.startTime, gap.endTime, gap.reason]
            )
        }
    }

    public func gaps(meetingID: String) throws -> [CaptureGap] {
        try database.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM capture_gaps WHERE meeting_id = ? ORDER BY start_time, id",
                arguments: [meetingID]
            ).map(decodeGap)
        }
    }

    public func upsertSegments(_ segments: [TranscriptSegment]) throws {
        guard !segments.isEmpty else { return }
        for segment in segments { try validate(segment) }
        try database.write { db in
            for meetingID in Set(segments.map(\.meetingID)) {
                try ensureOutsideRedactions(db, meetingID: meetingID,
                                            segments: segments.filter { $0.meetingID == meetingID })
            }
            var changedMeetingIDs = Set<String>()
            for incoming in segments {
                    let existingRow = try Row.fetchOne(
                        db,
                        sql: "SELECT * FROM transcript_segments WHERE meeting_id = ? AND id = ?",
                        arguments: [incoming.meetingID, incoming.id]
                    )
                    let existing = existingRow.map(decodeSegment)
                    var saved = incoming
                    if let existing, existing.isEdited {
                        saved.text = existing.text
                        saved.isEdited = true
                        saved.words = existing.words; saved.recognitionEvidence = existing.recognitionEvidence
                    } else if let existing, existing.text != incoming.text {
                        changedMeetingIDs.insert(incoming.meetingID)
                    }

                    try db.execute(
                        sql: """
                            INSERT INTO transcript_segments
                                (meeting_id, id, window_id, track, start_time, end_time, text,
                                 speaker_id, is_uncertain, is_provisional, is_edited)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                            ON CONFLICT(meeting_id, id) DO UPDATE SET
                                window_id = excluded.window_id,
                                track = excluded.track,
                                start_time = excluded.start_time,
                                end_time = excluded.end_time,
                                text = excluded.text,
                                speaker_id = excluded.speaker_id,
                                is_uncertain = excluded.is_uncertain,
                                is_provisional = excluded.is_provisional,
                                is_edited = excluded.is_edited
                            """,
                        arguments: segmentArguments(saved)
                    )
                    try replaceFTSRow(db, segment: saved)
            }
            for meetingID in changedMeetingIDs {
                try db.execute(
                    sql: "UPDATE meetings SET transcript_revision = transcript_revision + 1 WHERE id = ?",
                    arguments: [meetingID]
                )
            }
        }
    }

    /// Reconciles one ASR window without discarding human corrections or already-final rows.
    /// Stale machine-produced provisional rows are removed in the same transaction as inserts,
    /// updates, FTS maintenance, and the transcript revision change.
    public func replaceSegments(
        meetingID: String,
        windowID: String,
        segments: [TranscriptSegment],
        isFinal: Bool = false,
        reconcileFinal: Bool = false
    ) throws {
        guard AppPaths.isSafeIdentifier(meetingID), AppPaths.isSafeIdentifier(windowID),
              Set(segments.map(\.id)).count == segments.count else {
            throw EchoCoreError.invalidValue("transcript window")
        }
        for segment in segments {
            try validate(segment)
            guard segment.meetingID == meetingID, segment.windowID == windowID else {
                throw EchoCoreError.invalidValue("segment does not belong to requested window")
            }
        }

        try database.write { db in
            try ensureOutsideRedactions(db, meetingID: meetingID, segments: segments)
            guard try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM meetings WHERE id = ?)",
                arguments: [meetingID]
            ) == true else {
                throw EchoCoreError.meetingNotFound(meetingID)
            }

            let before = try Row.fetchAll(
                db,
                sql: "SELECT * FROM transcript_segments WHERE meeting_id = ? AND window_id = ?",
                arguments: [meetingID, windowID]
            ).map(decodeSegment)
            let incomingIDs = Set(segments.map(\.id))

            for existing in before where
                !incomingIDs.contains(existing.id) &&
                !existing.isEdited &&
                (existing.isProvisional || reconcileFinal)
            {
                try db.execute(
                    sql: "DELETE FROM segment_fts WHERE meeting_id = ? AND segment_id = ?",
                    arguments: [meetingID, existing.id]
                )
                try db.execute(
                    sql: "DELETE FROM transcript_segments WHERE meeting_id = ? AND id = ?",
                    arguments: [meetingID, existing.id]
                )
            }

            if isFinal {
                for existing in before where
                    !incomingIDs.contains(existing.id) && existing.isEdited && existing.isProvisional
                {
                    try db.execute(
                        sql: "UPDATE transcript_segments SET is_provisional = 0 WHERE meeting_id = ? AND id = ?",
                        arguments: [meetingID, existing.id]
                    )
                }
            }

            let beforeByID = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0) })
            for incoming in segments {
                var saved = incoming
                if let existing = beforeByID[incoming.id], existing.isEdited {
                    saved.text = existing.text
                    saved.isEdited = true
                        saved.words = existing.words; saved.recognitionEvidence = existing.recognitionEvidence
                }
                if isFinal { saved.isProvisional = false }
                try db.execute(
                    sql: """
                        INSERT INTO transcript_segments
                            (meeting_id, id, window_id, track, start_time, end_time, text,
                             speaker_id, is_uncertain, is_provisional, is_edited)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(meeting_id, id) DO UPDATE SET
                            window_id = excluded.window_id,
                            track = excluded.track,
                            start_time = excluded.start_time,
                            end_time = excluded.end_time,
                            text = excluded.text,
                            speaker_id = excluded.speaker_id,
                            is_uncertain = excluded.is_uncertain,
                            is_provisional = excluded.is_provisional,
                            is_edited = excluded.is_edited
                        """,
                    arguments: segmentArguments(saved)
                )
                try replaceFTSRow(db, segment: saved)
            }

            let after = try Row.fetchAll(
                db,
                sql: "SELECT id, text, is_edited, is_provisional FROM transcript_segments WHERE meeting_id = ? AND window_id = ?",
                arguments: [meetingID, windowID]
            )
            let beforeSignature = before.map { SegmentRevisionSignature($0) }.sorted { $0.id < $1.id }
            let afterSignature = after.map { row in
                SegmentRevisionSignature(
                    id: row["id"], text: row["text"],
                    isEdited: row["is_edited"], isProvisional: row["is_provisional"]
                )
            }.sorted { $0.id < $1.id }
            if beforeSignature != afterSignature {
                try db.execute(
                    sql: "UPDATE meetings SET transcript_revision = transcript_revision + 1 WHERE id = ?",
                    arguments: [meetingID]
                )
            }
        }
    }

    public func segments(meetingID: String) throws -> [TranscriptSegment] {
        try database.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM transcript_segments WHERE meeting_id = ? ORDER BY start_time, end_time, id",
                arguments: [meetingID]
            ).map(decodeSegment)
        }
    }

    public func editSegment(id: String, text: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EchoCoreError.invalidValue("segment text")
        }
        try database.write { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM transcript_segments WHERE id = ?", arguments: [id])
            guard let row = rows.first else { throw EchoCoreError.recordNotFound(id) }
            guard rows.count == 1 else { throw EchoCoreError.ambiguousIdentifier(id) }
            var segment = decodeSegment(row)
            let changed = segment.text != text || !segment.isEdited
            segment.words = TranscriptTiming.preservingUnchangedWords(segment.words ?? [], old: segment.text, new: text)
            segment.text = text
            segment.isEdited = true
            try db.execute(
                sql: "UPDATE transcript_segments SET text = ?, is_edited = 1 WHERE meeting_id = ? AND id = ?",
                arguments: [text, segment.meetingID, id]
            )
            try replaceFTSRow(db, segment: segment)
            if changed {
                try db.execute(
                    sql: "UPDATE meetings SET transcript_revision = transcript_revision + 1 WHERE id = ?",
                    arguments: [segment.meetingID]
                )
            }
        }
    }

    public func upsertSpeaker(_ speaker: Speaker) throws {
        guard AppPaths.isSafeIdentifier(speaker.id), AppPaths.isSafeIdentifier(speaker.meetingID),
              !speaker.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EchoCoreError.invalidValue("speaker")
        }
        try database.write { db in
            let existing = try Row.fetchOne(
                db,
                sql: "SELECT * FROM speakers WHERE meeting_id = ? AND id = ?",
                arguments: [speaker.meetingID, speaker.id]
            ).map(decodeSpeaker)
            let saved = existing?.isVerified == true && !speaker.isVerified ? existing! : speaker
            try db.execute(
                sql: """
                    INSERT INTO speakers (meeting_id, id, label, is_verified) VALUES (?, ?, ?, ?)
                    ON CONFLICT(meeting_id, id) DO UPDATE SET
                        label = excluded.label, is_verified = excluded.is_verified
                    """,
                arguments: [saved.meetingID, saved.id, saved.label, saved.isVerified]
            )
        }
    }

    public func speakers(meetingID: String) throws -> [Speaker] {
        try database.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM speakers WHERE meeting_id = ? ORDER BY label COLLATE NOCASE, id",
                arguments: [meetingID]
            ).map(decodeSpeaker)
        }
    }

    public func renameSpeaker(id: String, label: String) throws {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EchoCoreError.invalidValue("speaker label") }
        try database.write { db in
            let rows = try Row.fetchAll(db, sql: "SELECT meeting_id FROM speakers WHERE id = ?", arguments: [id])
            guard !rows.isEmpty else { throw EchoCoreError.recordNotFound(id) }
            guard rows.count == 1 else { throw EchoCoreError.ambiguousIdentifier(id) }
            let meetingID: String = rows[0]["meeting_id"]
            try db.execute(
                sql: "UPDATE speakers SET label = ?, is_verified = 1 WHERE meeting_id = ? AND id = ?",
                arguments: [trimmed, meetingID, id]
            )
        }
    }

    public func addScreenshot(_ screenshot: ScreenshotRecord) throws {
        guard AppPaths.isSafeIdentifier(screenshot.id), AppPaths.isSafeIdentifier(screenshot.meetingID),
              screenshot.capturedAt.isFinite, screenshot.capturedAt >= 0 else {
            throw EchoCoreError.invalidValue("screenshot")
        }
        _ = try validatedAssetURL(meetingID: screenshot.meetingID, relativePath: screenshot.relativePath)
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO screenshots
                        (meeting_id, id, relative_path, captured_at, perceptual_hash, interpretation)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(meeting_id, id) DO UPDATE SET
                        relative_path = excluded.relative_path,
                        captured_at = excluded.captured_at,
                        perceptual_hash = excluded.perceptual_hash,
                        interpretation = excluded.interpretation
                    """,
                arguments: [
                    screenshot.meetingID, screenshot.id, screenshot.relativePath,
                    screenshot.capturedAt, screenshot.perceptualHash, screenshot.interpretation,
                ]
            )
        }
    }

    public func screenshots(meetingID: String) throws -> [ScreenshotRecord] {
        try database.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM screenshots WHERE meeting_id = ? ORDER BY captured_at, id",
                arguments: [meetingID]
            ).map(decodeScreenshot)
        }
    }

    public func saveNotes(_ notes: MeetingNotes) throws {
        guard AppPaths.isSafeIdentifier(notes.id), AppPaths.isSafeIdentifier(notes.meetingID), notes.transcriptRevision >= 0 else {
            throw EchoCoreError.invalidValue("meeting notes")
        }
        try database.write { db in
            let existing = try Row.fetchOne(
                db,
                sql: "SELECT * FROM meeting_notes WHERE meeting_id = ? AND id = ?",
                arguments: [notes.meetingID, notes.id]
            ).map { try decodeNotes($0) }
            let saved = existing?.isEdited == true && !notes.isEdited ? existing! : notes
            try db.execute(
                sql: """
                    INSERT INTO meeting_notes
                        (meeting_id, id, created_at, transcript_revision, summary_json,
                         decisions_json, action_items_json, is_edited, is_partial)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(meeting_id, id) DO UPDATE SET
                        created_at = excluded.created_at,
                        transcript_revision = excluded.transcript_revision,
                        summary_json = excluded.summary_json,
                        decisions_json = excluded.decisions_json,
                        action_items_json = excluded.action_items_json,
                        is_edited = excluded.is_edited,
                        is_partial = excluded.is_partial
                    """,
                arguments: [
                    saved.meetingID, saved.id, saved.createdAt.timeIntervalSince1970,
                    saved.transcriptRevision, try encode(saved.summary), try encode(saved.decisions),
                    try encode(saved.actionItems), saved.isEdited, saved.isPartial,
                ]
            )
            try db.execute(sql: "UPDATE meeting_notes SET provenance_json=? WHERE meeting_id=? AND id=?", arguments: [try encode(NotesProvenance(model: saved.model, transcriptVersionID: saved.transcriptVersionID)), saved.meetingID, saved.id])
        }
    }

    public func notes(meetingID: String) throws -> [MeetingNotes] {
        try database.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM meeting_notes WHERE meeting_id = ? ORDER BY created_at DESC, id",
                arguments: [meetingID]
            ).map { try decodeNotes($0) }
        }
    }

    public func enqueue(_ job: ProcessingJob) throws {
        try validate(job)
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO processing_jobs
                        (meeting_id, id, kind, status, payload, attempts, error, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(meeting_id, id) DO NOTHING
                    """,
                arguments: jobArguments(job)
            )
        }
    }

    public func jobs(meetingID: String? = nil) throws -> [ProcessingJob] {
        try database.read { db in
            let rows: [Row]
            if let meetingID {
                rows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM processing_jobs WHERE meeting_id = ? ORDER BY created_at, id",
                    arguments: [meetingID]
                )
            } else {
                rows = try Row.fetchAll(db, sql: "SELECT * FROM processing_jobs ORDER BY created_at, meeting_id, id")
            }
            return rows.map(decodeJob)
        }
    }

    public struct JobStatusSummary: Sendable, Equatable {
        public let queuedCount: Int
        public let failedDiarization: Bool
        public let firstFailure: String?
    }

    /// Small status read for frequent review refreshes; never loads job payloads.
    public func jobStatusSummary(meetingID: String) throws -> JobStatusSummary {
        try database.read { db in
            let queued = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM processing_jobs
                WHERE meeting_id=? AND status IN ('pending','running')
                """, arguments: [meetingID]) ?? 0
            let failedDiarization = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM processing_jobs
                              WHERE meeting_id=? AND kind='diarize' AND status='failed')
                """, arguments: [meetingID]) ?? false
            let firstFailure = try String.fetchOne(db, sql: """
                SELECT error FROM processing_jobs WHERE meeting_id=? AND status='failed'
                  AND error IS NOT NULL ORDER BY created_at,id LIMIT 1
                """, arguments: [meetingID])
            return JobStatusSummary(queuedCount: queued, failedDiarization: failedDiarization,
                                    firstFailure: firstFailure)
        }
    }

    public func processingJobIDs(meetingID: String) throws -> Set<String> {
        try database.read { db in
            Set(try String.fetchAll(db, sql: "SELECT id FROM processing_jobs WHERE meeting_id=?",
                                    arguments: [meetingID]))
        }
    }

    public func segments(meetingID: String, windowIDs: [String]) throws -> [TranscriptSegment] {
        guard !windowIDs.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: windowIDs.count).joined(separator: ",")
        return try database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM transcript_segments WHERE meeting_id=? AND window_id IN (\(placeholders)) ORDER BY start_time,end_time,id",
                             arguments: StatementArguments([meetingID] + windowIDs)).map(decodeSegment)
        }
    }

    public func unfinishedJobs(meetingID: String, kind: JobKind) throws -> [ProcessingJob] {
        try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM processing_jobs
                WHERE meeting_id=? AND kind=? AND status IN ('pending','failed')
                ORDER BY created_at,id
                """, arguments: [meetingID, kind.rawValue]).map(decodeJob)
        }
    }

    public func updateJob(_ job: ProcessingJob) throws {
        try validate(job)
        try database.write { db in
            try db.execute(
                sql: """
                    UPDATE processing_jobs SET
                        kind = ?, status = ?, payload = ?, attempts = ?, error = ?, created_at = ?
                    WHERE meeting_id = ? AND id = ?
                    """,
                arguments: [
                    job.kind.rawValue, job.status.rawValue, job.payload, job.attempts,
                    job.error, job.createdAt.timeIntervalSince1970, job.meetingID, job.id,
                ]
            )
            guard db.changesCount == 1 else { throw EchoCoreError.recordNotFound(job.id) }
        }
    }

    public func recoverRunningJobs() throws {
        try database.write { db in
            try db.execute(
                sql: """
                    UPDATE processing_jobs
                    SET status = ?, error = COALESCE(error, ?)
                    WHERE status = ?
                    """,
                arguments: [JobStatus.pending.rawValue, "Recovered after application interruption", JobStatus.running.rawValue]
            )
        }
    }

    public func search(_ query: String) throws -> [SearchHit] {
        guard let ftsQuery = Self.safeFTSQuery(query) else { return [] }
        return try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT s.*, m.title AS meeting_title
                    FROM segment_fts
                    JOIN transcript_segments s
                      ON s.meeting_id = segment_fts.meeting_id AND s.id = segment_fts.segment_id
                    JOIN meetings m ON m.id = s.meeting_id
                    WHERE segment_fts MATCH ?
                    ORDER BY bm25(segment_fts), s.start_time, s.id
                    """,
                arguments: [ftsQuery]
            ).map { row in
                SearchHit(segment: decodeSegment(row), meetingTitle: row["meeting_title"])
            }
        }
    }

    public func deleteMeeting(id: String) throws {
        deletionRecoveryLock.lock(); defer { deletionRecoveryLock.unlock() }
        try requireDeletionRecovered(meetingID: id)
        guard let meeting = try meeting(id: id) else { throw EchoCoreError.meetingNotFound(id) }
        let trackedChunks = try chunks(meetingID: id)
        let trackedScreenshots = try screenshots(meetingID: id)
        for chunk in trackedChunks {
            _ = try validatedAssetURL(meetingID: id, relativePath: chunk.relativePath)
        }
        for screenshot in trackedScreenshots {
            _ = try validatedAssetURL(meetingID: id, relativePath: screenshot.relativePath)
        }

        let fileManager = FileManager.default
        let source = paths.meetingDirectory(id)
        guard fileManager.fileExists(atPath: source.path) else { throw EchoCoreError.assetMissing(source.path) }
        let deletedRoot = paths.root.appendingPathComponent("Deleted Meetings", isDirectory: true)
        let tombstoneDirectory = deletedRoot.appendingPathComponent("\(id)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tombstoneDirectory, withIntermediateDirectories: false)
        let tombstone = DeletionTombstone(
            meeting: meeting,
            deletedAt: Date(),
            chunks: trackedChunks,
            screenshots: trackedScreenshots
        )
        let tombstoneData = try prettyEncoder().encode(tombstone)
        let tombstoneURL = tombstoneDirectory.appendingPathComponent("tombstone.json")
        do {
            try tombstoneData.write(to: tombstoneURL, options: .atomic)
            try Self.syncFile(tombstoneURL)
            try Self.syncDirectory(tombstoneDirectory)
            try database.write { db in
                try db.execute(
                    sql: "INSERT INTO meeting_tombstones (id, deleted_at, relative_path, metadata_json, state) VALUES (?, ?, ?, ?, ?)",
                    arguments: [
                        id, tombstone.deletedAt.timeIntervalSince1970,
                        tombstoneDirectory.lastPathComponent, tombstoneData,
                        DeletionState.prepared.rawValue,
                    ]
                )
            }
            try completePreparedDeletion(tombstone, directory: tombstoneDirectory, runCheckpoint: true)
        } catch {
            if try deletionState(meetingID: id) == .completed {
                rememberDeletionIssue(meetingID: id, error: error)
                throw error
            }
            do {
                try rollbackPreparedDeletion(meetingID: id, directory: tombstoneDirectory)
            } catch {
                rememberDeletionIssue(meetingID: id, error: error)
                throw error
            }
            throw error
        }
    }

    func exportSnapshot(meetingID: String) throws -> ExportSnapshot {
        try requireDeletionRecovered(meetingID: meetingID)
        return try database.read { db in
            guard let meetingRow = try Row.fetchOne(
                db,
                sql: "SELECT * FROM meetings WHERE id = ?",
                arguments: [meetingID]
            ) else { throw EchoCoreError.meetingNotFound(meetingID) }
            let chunks = try Row.fetchAll(
                db,
                sql: "SELECT * FROM chunks WHERE meeting_id = ? ORDER BY start_time, track, id",
                arguments: [meetingID]
            ).map(decodeChunk)
            let gaps = try Row.fetchAll(
                db,
                sql: "SELECT * FROM capture_gaps WHERE meeting_id = ? ORDER BY start_time, id",
                arguments: [meetingID]
            ).map(decodeGap)
            let segments = try Row.fetchAll(
                db,
                sql: "SELECT * FROM transcript_segments WHERE meeting_id = ? ORDER BY start_time, end_time, id",
                arguments: [meetingID]
            ).map(decodeSegment)
            let speakers = try Row.fetchAll(
                db,
                sql: "SELECT * FROM speakers WHERE meeting_id = ? ORDER BY label COLLATE NOCASE, id",
                arguments: [meetingID]
            ).map(decodeSpeaker)
            let screenshots = try Row.fetchAll(
                db,
                sql: "SELECT * FROM screenshots WHERE meeting_id = ? ORDER BY captured_at, id",
                arguments: [meetingID]
            ).map(decodeScreenshot)

            // The test checkpoint runs while the DatabaseQueue still owns this
            // read transaction, proving a waiting writer cannot split evidence
            // rows from the notes that cite them.
            exportSnapshotCheckpoint()

            let notes = try Row.fetchAll(
                db,
                sql: "SELECT * FROM meeting_notes WHERE meeting_id = ? ORDER BY created_at DESC, id",
                arguments: [meetingID]
            ).map { try decodeNotes($0) }
            let jobs = try Row.fetchAll(
                db,
                sql: "SELECT * FROM processing_jobs WHERE meeting_id = ? ORDER BY created_at, id",
                arguments: [meetingID]
            ).map(decodeJob)
            return ExportSnapshot(
                meeting: decodeMeeting(meetingRow),
                chunks: chunks,
                gaps: gaps,
                segments: segments,
                speakers: speakers,
                screenshots: screenshots,
                notes: notes,
                jobs: jobs,
                transcriptVersion: try String.fetchOne(db, sql: "SELECT active_version FROM meeting_configuration WHERE meeting_id=?", arguments: [meetingID]) ?? "legacy-" + meetingID,
                annotations: try Data.fetchAll(db, sql: "SELECT payload FROM transcript_annotations WHERE meeting_id=? ORDER BY start_time,id", arguments: [meetingID]).map { try decode(TranscriptAnnotation.self, from: $0) },
                speakerGrouping: try Data.fetchAll(db, sql: "SELECT payload FROM speaker_grouping_runs WHERE meeting_id=? ORDER BY created_at DESC,id", arguments: [meetingID]).map { try decode(SpeakerGroupingRun.self, from: $0) }
            )
        }
    }

    func validatedAssetURL(meetingID: String, relativePath: String) throws -> URL {
        let url = try paths.resolveMeetingAsset(meetingID: meetingID, relativePath: relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            let compressed: String? = try database.read { db in
                try String.fetchOne(db, sql: """
                    SELECT r.stored_path FROM chunks c
                    JOIN audio_representations r ON r.meeting_id=c.meeting_id AND r.chunk_id=c.id
                    WHERE c.meeting_id=? AND c.relative_path=? AND r.state='ready'
                    """, arguments: [meetingID, relativePath])
            }
            guard let compressed else { throw EchoCoreError.assetMissing(relativePath) }
            let packed = try paths.resolveMeetingAsset(meetingID: meetingID, relativePath: compressed)
            let values = try packed.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw EchoCoreError.assetMissing(compressed)
            }
            return packed
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw EchoCoreError.assetNotRegularFile(relativePath)
        }
        return url
    }
}

extension MeetingStore {
    static func ensureManagedDirectory(_ directory: URL, within root: URL) throws {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard isDirectory.boolValue, values.isDirectory == true, values.isSymbolicLink != true else {
                throw EchoCoreError.assetNotRegularFile(directory.path)
            }
        } else {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        }

        let canonicalRoot = root.resolvingSymlinksInPath()
        let canonicalDirectory = directory.resolvingSymlinksInPath()
        let rootPrefix = canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/"
        guard canonicalDirectory.path.hasPrefix(rootPrefix) else {
            throw EchoCoreError.invalidRelativePath(directory.path)
        }
    }

    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createCoreSchema") { db in
            try db.execute(sql: """
                CREATE TABLE meetings (
                    id TEXT PRIMARY KEY NOT NULL,
                    title TEXT NOT NULL,
                    started_at REAL NOT NULL,
                    ended_at REAL,
                    state TEXT NOT NULL,
                    language TEXT NOT NULL,
                    source_name TEXT NOT NULL,
                    uses_echo_cancellation INTEGER NOT NULL,
                    transcript_revision INTEGER NOT NULL CHECK (transcript_revision >= 0)
                );

                CREATE TABLE chunks (
                    meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                    id TEXT NOT NULL,
                    epoch_id TEXT NOT NULL,
                    track TEXT NOT NULL,
                    relative_path TEXT NOT NULL,
                    start_time REAL NOT NULL,
                    duration REAL NOT NULL,
                    sample_rate REAL NOT NULL,
                    frame_count INTEGER NOT NULL,
                    sha256 TEXT NOT NULL,
                    PRIMARY KEY (meeting_id, id)
                );
                CREATE INDEX chunks_timeline ON chunks(meeting_id, start_time, track);

                CREATE TABLE capture_gaps (
                    meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                    id TEXT NOT NULL,
                    start_time REAL NOT NULL,
                    end_time REAL,
                    reason TEXT NOT NULL,
                    PRIMARY KEY (meeting_id, id)
                );

                CREATE TABLE transcript_segments (
                    meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                    id TEXT NOT NULL,
                    window_id TEXT NOT NULL,
                    track TEXT NOT NULL,
                    start_time REAL NOT NULL,
                    end_time REAL NOT NULL,
                    text TEXT NOT NULL,
                    speaker_id TEXT,
                    is_uncertain INTEGER NOT NULL,
                    is_provisional INTEGER NOT NULL,
                    is_edited INTEGER NOT NULL,
                    PRIMARY KEY (meeting_id, id)
                );
                CREATE INDEX segments_timeline ON transcript_segments(meeting_id, start_time, end_time);
                CREATE VIRTUAL TABLE segment_fts USING fts5(
                    meeting_id UNINDEXED,
                    segment_id UNINDEXED,
                    text,
                    tokenize = 'unicode61 remove_diacritics 2'
                );

                CREATE TABLE speakers (
                    meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                    id TEXT NOT NULL,
                    label TEXT NOT NULL,
                    is_verified INTEGER NOT NULL,
                    PRIMARY KEY (meeting_id, id)
                );

                CREATE TABLE screenshots (
                    meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                    id TEXT NOT NULL,
                    relative_path TEXT NOT NULL,
                    captured_at REAL NOT NULL,
                    perceptual_hash TEXT NOT NULL,
                    interpretation TEXT,
                    PRIMARY KEY (meeting_id, id)
                );

                CREATE TABLE meeting_notes (
                    meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                    id TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    transcript_revision INTEGER NOT NULL,
                    summary_json BLOB NOT NULL,
                    decisions_json BLOB NOT NULL,
                    action_items_json BLOB NOT NULL,
                    is_edited INTEGER NOT NULL,
                    is_partial INTEGER NOT NULL,
                    PRIMARY KEY (meeting_id, id)
                );

                CREATE TABLE processing_jobs (
                    meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                    id TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    status TEXT NOT NULL,
                    payload TEXT NOT NULL,
                    attempts INTEGER NOT NULL CHECK (attempts >= 0),
                    error TEXT,
                    created_at REAL NOT NULL,
                    PRIMARY KEY (meeting_id, id)
                );
                CREATE INDEX jobs_status ON processing_jobs(status, created_at);

                CREATE TABLE meeting_tombstones (
                    id TEXT PRIMARY KEY NOT NULL,
                    deleted_at REAL NOT NULL,
                    relative_path TEXT NOT NULL,
                    metadata_json BLOB NOT NULL
                );
                """)
        }
        migrator.registerMigration("addDeletionState") { db in
            try db.alter(table: "meeting_tombstones") { table in
                table.add(column: "state", .text).notNull().defaults(to: DeletionState.prepared.rawValue)
            }
        }
        migrator.registerMigration("addSpeechRecognitionModel") { db in
            try db.alter(table: "meetings") { table in
                table.add(column: "speech_model", .text).notNull().defaults(to: "whisper")
            }
        }
        migrator.registerMigration("reviewAndModelCatalogV2") { db in
            try db.execute(sql: """
                ALTER TABLE transcript_segments ADD COLUMN review_json BLOB;
                CREATE TABLE app_preferences (key TEXT PRIMARY KEY NOT NULL, value BLOB NOT NULL);
                CREATE TABLE vocabulary (id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL);
                CREATE TABLE meeting_configuration (meeting_id TEXT PRIMARY KEY NOT NULL REFERENCES meetings(id) ON DELETE CASCADE, active_version TEXT NOT NULL, payload BLOB);
                INSERT INTO meeting_configuration(meeting_id, active_version) SELECT id, 'legacy-' || id FROM meetings;
                CREATE TABLE transcript_versions (id TEXT PRIMARY KEY NOT NULL, meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE, created_at REAL NOT NULL, status TEXT NOT NULL, payload BLOB NOT NULL);
                CREATE TABLE version_segments (version_id TEXT NOT NULL REFERENCES transcript_versions(id) ON DELETE CASCADE, id TEXT NOT NULL, window_id TEXT NOT NULL, start_time REAL NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(version_id,id));
                CREATE INDEX version_segments_time ON version_segments(version_id,start_time);
                CREATE TABLE transcript_annotations (id TEXT PRIMARY KEY NOT NULL, meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE, start_time REAL NOT NULL, payload BLOB NOT NULL);
                CREATE INDEX annotations_meeting ON transcript_annotations(meeting_id,start_time);
                ALTER TABLE meeting_notes ADD COLUMN provenance_json BLOB;
                CREATE TABLE cleanup_journal (id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL);
                """)
        }
        migrator.registerMigration("productionRecordingModesV1") { db in
            try db.execute(sql: """
                ALTER TABLE meetings ADD COLUMN recording_mode TEXT NOT NULL DEFAULT 'online';
                CREATE TABLE speaker_grouping_runs (id TEXT PRIMARY KEY NOT NULL, meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE, version_id TEXT NOT NULL, created_at REAL NOT NULL, payload BLOB NOT NULL);
                CREATE INDEX speaker_runs_meeting ON speaker_grouping_runs(meeting_id, version_id, created_at);
                """)
        }
        migrator.registerMigration("captureSessionSettingsV1") { db in
            try db.execute(sql: """
                CREATE TABLE capture_session_settings (
                    meeting_id TEXT PRIMARY KEY NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                    payload BLOB NOT NULL
                );
                CREATE TABLE capture_track_events (
                    meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                    id TEXT NOT NULL,
                    track TEXT NOT NULL,
                    start_time REAL NOT NULL,
                    end_time REAL,
                    cause TEXT NOT NULL,
                    epoch_id TEXT,
                    payload BLOB NOT NULL,
                    PRIMARY KEY(meeting_id,id)
                );
                CREATE INDEX capture_track_events_timeline ON capture_track_events(meeting_id,track,start_time,end_time);
                CREATE TABLE microphone_processing_epochs (
                    meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                    epoch_id TEXT NOT NULL,
                    start_time REAL NOT NULL,
                    acoustic_mode TEXT NOT NULL,
                    payload BLOB NOT NULL,
                    PRIMARY KEY(meeting_id,epoch_id)
                );
                CREATE INDEX microphone_processing_epochs_time ON microphone_processing_epochs(meeting_id,start_time);
                CREATE INDEX transcript_segments_order ON transcript_segments(meeting_id,start_time,end_time,id);
                """)
        }
        migrator.registerMigration("liveTranscriptionPolicyV1") { db in
            try db.execute(sql: """
                CREATE TABLE live_transcription_policy (
                    meeting_id TEXT PRIMARY KEY NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                    payload BLOB NOT NULL
                );
                """)
        }
        migrator.registerMigration("audioRepresentationsV1") { db in
            try db.execute(sql: """
                CREATE TABLE audio_representations (
                    meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                    chunk_id TEXT NOT NULL,
                    codec TEXT NOT NULL,
                    codec_version INTEGER NOT NULL,
                    stored_path TEXT NOT NULL,
                    stored_size INTEGER NOT NULL,
                    decoded_size INTEGER NOT NULL,
                    stored_sha256 TEXT NOT NULL,
                    canonical_sha256 TEXT NOT NULL,
                    state TEXT NOT NULL,
                    PRIMARY KEY(meeting_id,chunk_id)
                );
                CREATE INDEX audio_representations_state ON audio_representations(state,meeting_id);
                """)
        }
        migrator.registerMigration("audioRedactionsV1") { db in
            try db.execute(sql: """
                CREATE TABLE audio_redactions (
                    id TEXT PRIMARY KEY NOT NULL,
                    meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                    start_time REAL NOT NULL,
                    end_time REAL NOT NULL,
                    state TEXT NOT NULL,
                    payload BLOB NOT NULL
                );
                CREATE INDEX audio_redactions_pending ON audio_redactions(state,meeting_id);
                """)
        }
        migrator.registerMigration("pendingProcessingIndexesV1") { db in
            try db.execute(sql: "CREATE INDEX processing_jobs_meeting_kind_status ON processing_jobs(meeting_id,kind,status,created_at,id)")
        }
        migrator.registerMigration("processingReviewIndexesV1") { db in
            try db.execute(sql: "CREATE INDEX transcript_segments_window ON transcript_segments(meeting_id,window_id,start_time,id)")
            try db.execute(sql: "CREATE INDEX version_segments_window ON version_segments(version_id,window_id,start_time,id)")
            try db.execute(sql: "CREATE INDEX chunks_track_start ON chunks(meeting_id,track,start_time)")
        }
        return migrator
    }

    public var deletionRecoveryIssues: [MeetingAssetRecoveryIssue] {
        deletionIssueLock.lock(); defer { deletionIssueLock.unlock() }
        return deletionIssues.values.sorted { $0.meetingID < $1.meetingID }
    }

    func requireDeletionRecovered(meetingID: String) throws {
        deletionIssueLock.lock(); let issue = deletionIssues[meetingID]; deletionIssueLock.unlock()
        if let issue { throw EchoCoreError.deletionRecoveryRequired(issue.message) }
    }

    private func rememberDeletionIssue(meetingID: String, error: Error) {
        deletionIssueLock.lock(); defer { deletionIssueLock.unlock() }
        deletionIssues[meetingID] = MeetingAssetRecoveryIssue(meetingID: meetingID, message: error.localizedDescription)
    }

    @discardableResult
    public func recoverDeletionTransactions(meetingID: String? = nil) throws -> [MeetingAssetRecoveryIssue] {
        try reconcileDeletionTransactions(onlyMeetingID: meetingID)
    }

    @discardableResult
    func reconcileDeletionTransactions(performRecovery: Bool = true, onlyMeetingID: String? = nil) throws -> [MeetingAssetRecoveryIssue] {
        deletionRecoveryLock.lock(); defer { deletionRecoveryLock.unlock() }
        var issues: [String: MeetingAssetRecoveryIssue] = [:]
        func record(_ id: String, _ error: Error) throws {
            // Actual database failures still require the library-wide recovery screen.
            if error is DatabaseError { throw error }
            issues[id] = MeetingAssetRecoveryIssue(meetingID: id, message: error.localizedDescription)
        }
        let fileManager = FileManager.default
        let deletedRoot = paths.root.appendingPathComponent("Deleted Meetings", isDirectory: true)
        let directories = try fileManager.contentsOfDirectory(
            at: deletedRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        let knownRows = try database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM meeting_tombstones ORDER BY deleted_at, id")
        }
        let knownPaths = Set(knownRows.map { $0["relative_path"] as String })
        for directory in directories where !knownPaths.contains(directory.lastPathComponent) {
            // Managed names end in a UUID. Recover the owning ID even if JSON is damaged.
            let name = directory.lastPathComponent
            let id = name.count > 37 && UUID(uuidString: String(name.suffix(36))) != nil
                ? String(name.dropLast(37)) : name
            if let onlyMeetingID, id != onlyMeetingID { continue }
            do {
                let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
                let tombstoneURL = directory.appendingPathComponent("tombstone.json")
                guard fileManager.fileExists(atPath: tombstoneURL.path) else { continue }
                let tombstoneData = try Data(contentsOf: tombstoneURL)
                let tombstone = try deletionDecoder().decode(DeletionTombstone.self, from: tombstoneData)
                guard AppPaths.isSafeIdentifier(tombstone.meeting.id),
                      name.hasPrefix(tombstone.meeting.id + "-") else {
                    throw EchoCoreError.deletionRecoveryRequired(directory.path)
                }
                try database.write { db in
                    try db.execute(
                        sql: """
                            INSERT INTO meeting_tombstones
                                (id, deleted_at, relative_path, metadata_json, state)
                            VALUES (?, ?, ?, ?, ?)
                            ON CONFLICT(id) DO NOTHING
                            """,
                        arguments: [
                            tombstone.meeting.id, tombstone.deletedAt.timeIntervalSince1970,
                            directory.lastPathComponent, tombstoneData, DeletionState.prepared.rawValue,
                        ]
                    )
                }
            } catch { try record(id, error) }
        }

        let rows = try database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM meeting_tombstones ORDER BY deleted_at, id")
        }
        for row in rows {
            let meetingID: String = row["id"]
            if let onlyMeetingID, meetingID != onlyMeetingID { continue }
            let relativePath: String = row["relative_path"]
            guard AppPaths.isSafeIdentifier(relativePath) else {
                try record(meetingID, EchoCoreError.deletionRecoveryRequired(relativePath))
                continue
            }
            let state = DeletionState(rawValue: row["state"]) ?? .prepared
            let directory = deletedRoot.appendingPathComponent(relativePath, isDirectory: true)
            guard performRecovery else {
                issues[meetingID] = MeetingAssetRecoveryIssue(meetingID: meetingID, message: "Deletion recovery pending at " + directory.path)
                continue
            }
            do {
                if state == .completed {
                    try purgeCompletedDeletion(meetingID: meetingID, directory: directory)
                    continue
                } else if state == .cancelled {
                    try cleanupCancelledDeletion(meetingID: meetingID, directory: directory)
                    continue
                }
                let metadata: Data = row["metadata_json"]
                let tombstone = try deletionDecoder().decode(DeletionTombstone.self, from: metadata)
                try completePreparedDeletion(tombstone, directory: directory, runCheckpoint: false)
            } catch { try record(meetingID, error) }
        }
        deletionIssueLock.lock()
        if let onlyMeetingID { deletionIssues.removeValue(forKey: onlyMeetingID); deletionIssues.merge(issues) { _, new in new } }
        else { deletionIssues = issues }
        deletionIssueLock.unlock()
        return issues.values.sorted { $0.meetingID < $1.meetingID }
    }

    fileprivate func completePreparedDeletion(
        _ tombstone: DeletionTombstone,
        directory: URL,
        runCheckpoint: Bool
    ) throws {
        let fileManager = FileManager.default
        let meetingID = tombstone.meeting.id
        let source = paths.meetingDirectory(meetingID)
        let backup = directory.appendingPathComponent("assets", isDirectory: true)
        let sourceExists = fileManager.fileExists(atPath: source.path)
        let backupExists = fileManager.fileExists(atPath: backup.path)

        if sourceExists && backupExists {
            throw EchoCoreError.deletionRecoveryRequired(backup.path)
        }
        if sourceExists {
            try fileManager.moveItem(at: source, to: backup)
            try Self.syncDirectory(directory)
            try Self.syncDirectory(source.deletingLastPathComponent())
        } else if !backupExists {
            throw EchoCoreError.deletionRecoveryRequired(directory.path)
        }

        if runCheckpoint { try deletionCheckpoint(source, backup) }
        try database.write { db in
            try db.execute(sql: "DELETE FROM segment_fts WHERE meeting_id = ?", arguments: [meetingID])
            try db.execute(sql: "DELETE FROM meetings WHERE id = ?", arguments: [meetingID])
            try db.execute(
                sql: "UPDATE meeting_tombstones SET state = ? WHERE id = ?",
                arguments: [DeletionState.completed.rawValue, meetingID]
            )
        }
        try purgeCompletedDeletion(meetingID: meetingID, directory: directory)
    }

    func purgeCompletedDeletion(meetingID: String, directory: URL) throws {
        guard try meeting(id: meetingID) == nil else {
            throw EchoCoreError.deletionRecoveryRequired(directory.path)
        }
        do {
            try purgeCheckpoint(directory)
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
            try Self.syncDirectory(directory.deletingLastPathComponent())
        } catch {
            throw EchoCoreError.deletionPurgeRequired(directory.path)
        }
        try database.write { db in
            try db.execute(
                sql: "DELETE FROM meeting_tombstones WHERE id = ? AND state = ?",
                arguments: [meetingID, DeletionState.completed.rawValue]
            )
        }
    }

    fileprivate func deletionState(meetingID: String) throws -> DeletionState? {
        try database.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT state FROM meeting_tombstones WHERE id = ?",
                arguments: [meetingID]
            ).flatMap(DeletionState.init(rawValue:))
        }
    }

    func rollbackPreparedDeletion(meetingID: String, directory: URL) throws {
        let fileManager = FileManager.default
        let source = paths.meetingDirectory(meetingID)
        let backup = directory.appendingPathComponent("assets", isDirectory: true)
        let sourceExists = fileManager.fileExists(atPath: source.path)
        let backupExists = fileManager.fileExists(atPath: backup.path)

        if backupExists {
            guard !sourceExists else { throw EchoCoreError.deletionRecoveryRequired(backup.path) }
            do {
                try fileManager.moveItem(at: backup, to: source)
                try Self.syncDirectory(directory)
                try Self.syncDirectory(source.deletingLastPathComponent())
            } catch {
                throw EchoCoreError.deletionRecoveryRequired(backup.path)
            }
        } else if !sourceExists {
            throw EchoCoreError.deletionRecoveryRequired(directory.path)
        }

        try database.write { db in
            try db.execute(
                sql: "UPDATE meeting_tombstones SET state = ? WHERE id = ?",
                arguments: [DeletionState.cancelled.rawValue, meetingID]
            )
        }
        try cleanupCancelledDeletion(meetingID: meetingID, directory: directory)
    }

    func cleanupCancelledDeletion(meetingID: String, directory: URL) throws {
        let fileManager = FileManager.default
        let source = paths.meetingDirectory(meetingID)
        let backup = directory.appendingPathComponent("assets", isDirectory: true)
        if fileManager.fileExists(atPath: backup.path) {
            guard !fileManager.fileExists(atPath: source.path) else {
                throw EchoCoreError.deletionRecoveryRequired(backup.path)
            }
            try fileManager.moveItem(at: backup, to: source)
        }
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
        try database.write { db in
            try db.execute(sql: "DELETE FROM meeting_tombstones WHERE id = ? AND state = ?", arguments: [meetingID, DeletionState.cancelled.rawValue])
        }
    }

    func reconcileUnfinishedChunkIntents(onlyMeetingID: String? = nil) throws {
        let fileManager = FileManager.default
        let candidates: [Meeting]
        if let onlyMeetingID { candidates = try meeting(id: onlyMeetingID).map { [$0] } ?? [] }
        else { candidates = try meetings() }
        for meeting in candidates {
            let directory = paths.meetingDirectory(meeting.id).appendingPathComponent("audio", isDirectory: true)
            guard fileManager.fileExists(atPath: directory.path) else { continue }
            let existing = try chunks(meetingID: meeting.id)
            for url in try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) where url.lastPathComponent.hasSuffix(".caf.intent.json") {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { throw EchoCoreError.assetNotRegularFile(url.path) }
                let intent = try decoder.decode(CaptureChunkIntent.self, from: Data(contentsOf: url))
                guard intent.meetingID == meeting.id, AppPaths.isSafeIdentifier(intent.id), AppPaths.isSafeIdentifier(intent.epochID),
                      intent.track == .microphone || intent.track == .remote,
                      intent.startTime.isFinite, intent.startTime >= 0,
                      intent.sampleRate.isFinite, intent.sampleRate > 0, intent.channels > 0,
                      intent.relativePath == "audio/\(intent.track.rawValue)-\(intent.id).caf" else { throw EchoCoreError.invalidValue("unfinished chunk intent") }
                let finalURL = try paths.resolveMeetingAsset(meetingID: meeting.id, relativePath: intent.relativePath)
                guard finalURL.appendingPathExtension("intent.json").standardizedFileURL == url.standardizedFileURL else { throw EchoCoreError.invalidRelativePath(url.path) }
                // Resolve the partial through the same symlink/traversal protection;
                // never import its unverified bytes as a completed recording.
                let partialPath = String(intent.relativePath.dropLast(4)) + ".partial.caf"
                let partialURL = try paths.resolveMeetingAsset(meetingID: meeting.id, relativePath: partialPath)
                if fileManager.fileExists(atPath: partialURL.path) {
                    let partialValues = try partialURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard partialValues.isRegularFile == true, partialValues.isSymbolicLink != true else { throw EchoCoreError.assetNotRegularFile(partialURL.path) }
                }
                if let chunk = existing.first(where: { $0.id == intent.id }) {
                    guard chunk.relativePath == intent.relativePath, chunk.epochID == intent.epochID, chunk.track == intent.track, chunk.startTime == intent.startTime else { throw EchoCoreError.invalidValue("unfinished chunk conflicts with saved metadata") }
                    // A crash after SQLite commit but before intent cleanup is safe.
                    try addChunk(chunk)
                } else {
                    try addGap(CaptureGap(id: "unfinished-" + intent.id, meetingID: meeting.id, startTime: intent.startTime, endTime: nil, reason: "Unfinalized \(intent.track.rawValue) audio after an interruption. Any partial bytes and timing metadata are retained locally, but are not verified playback or transcript audio."))
                }
            }
        }
    }

    func reconcileChunkSidecars(onlyMeetingID: String? = nil) throws {
        let fileManager = FileManager.default
        let candidates: [Meeting]
        if let onlyMeetingID { candidates = try meeting(id: onlyMeetingID).map { [$0] } ?? [] }
        else { candidates = try meetings() }
        for meeting in candidates {
            let audioDirectory = paths.meetingDirectory(meeting.id).appendingPathComponent("audio", isDirectory: true)
            guard fileManager.fileExists(atPath: audioDirectory.path) else { continue }
            let entries = try fileManager.contentsOfDirectory(
                at: audioDirectory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
            for sidecar in entries where sidecar.lastPathComponent.hasSuffix(".caf.chunk.json") {
                let values = try sidecar.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw EchoCoreError.assetNotRegularFile(sidecar.path)
                }
                let chunk = try decoder.decode(CapturedChunk.self, from: Data(contentsOf: sidecar))
                try validate(chunk)
                guard chunk.meetingID == meeting.id else {
                    throw EchoCoreError.invalidValue("chunk sidecar meeting mismatch")
                }
                let finalURL = try paths.resolveMeetingAsset(
                    meetingID: meeting.id,
                    relativePath: chunk.relativePath
                )
                guard finalURL.appendingPathExtension("chunk.json").standardizedFileURL == sidecar.standardizedFileURL else {
                    throw EchoCoreError.invalidRelativePath(sidecar.path)
                }
                let partialURL = finalURL.deletingPathExtension().appendingPathExtension("partial.caf")
                let finalExists = fileManager.fileExists(atPath: finalURL.path)
                let partialExists = fileManager.fileExists(atPath: partialURL.path)
                if finalExists && partialExists {
                    throw EchoCoreError.deletionRecoveryRequired(partialURL.path)
                }
                let candidate: URL
                if finalExists {
                    candidate = finalURL
                } else if partialExists {
                    candidate = partialURL
                } else {
                    throw EchoCoreError.assetMissing(chunk.relativePath)
                }

                let digest = try Self.sha256(candidate)
                guard digest.caseInsensitiveCompare(chunk.sha256) == .orderedSame else {
                    throw EchoCoreError.checksumMismatch(candidate.path)
                }
                if candidate == partialURL {
                    try fileManager.moveItem(at: partialURL, to: finalURL)
                    try Self.syncDirectory(audioDirectory)
                }
                try addChunk(chunk)
            }
        }
    }

    static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let block = try handle.read(upToCount: 1024 * 1024), !block.isEmpty {
            hash.update(data: block)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func syncFile(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw CocoaError(.fileReadUnknown) }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    static func syncDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw CocoaError(.fileReadUnknown) }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    func deletionDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func ensureSafeMeetingDirectory(_ directory: URL, meetingID: String) throws {
        guard AppPaths.isSafeIdentifier(meetingID) else { throw EchoCoreError.invalidIdentifier(meetingID) }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard isDirectory.boolValue, values.isDirectory == true, values.isSymbolicLink != true else {
                throw EchoCoreError.assetNotRegularFile(directory.path)
            }
        } else {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }
    }

    func validate(_ meeting: Meeting) throws {
        guard meeting.recordingMode != .inPerson || !meeting.usesEchoCancellation else { throw EchoCoreError.invalidValue("In-person recording cannot use echo cancellation") }
        guard AppPaths.isSafeIdentifier(meeting.id), meeting.startedAt.timeIntervalSince1970.isFinite,
              meeting.endedAt.map({ $0 >= meeting.startedAt }) ?? true,
              meeting.transcriptRevision >= 0 else { throw EchoCoreError.invalidValue("meeting") }
    }

    func validate(_ chunk: CapturedChunk) throws {
        guard AppPaths.isSafeIdentifier(chunk.id), AppPaths.isSafeIdentifier(chunk.meetingID),
              AppPaths.isSafeIdentifier(chunk.epochID), chunk.startTime.isFinite, chunk.startTime >= 0,
              chunk.duration.isFinite, chunk.duration > 0, chunk.sampleRate.isFinite, chunk.sampleRate > 0,
              chunk.frameCount > 0, !chunk.sha256.isEmpty else { throw EchoCoreError.invalidValue("captured chunk") }
    }

    func validate(_ segment: TranscriptSegment) throws {
        guard AppPaths.isSafeIdentifier(segment.id), AppPaths.isSafeIdentifier(segment.meetingID),
              AppPaths.isSafeIdentifier(segment.windowID), segment.startTime.isFinite, segment.startTime >= 0,
              segment.endTime.isFinite, segment.endTime >= segment.startTime else {
            throw EchoCoreError.invalidValue("transcript segment")
        }
    }

    func validate(_ job: ProcessingJob) throws {
        guard AppPaths.isSafeIdentifier(job.id), AppPaths.isSafeIdentifier(job.meetingID), job.attempts >= 0,
              job.createdAt.timeIntervalSince1970.isFinite else { throw EchoCoreError.invalidValue("processing job") }
    }

    static func safeFTSQuery(_ query: String) -> String? {
        let tokens = query.unicodeScalars.split { scalar in
            !CharacterSet.alphanumerics.contains(scalar)
        }.map(String.init)
        guard !tokens.isEmpty else { return nil }
        return tokens.map { token in
            let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }.joined(separator: " AND ")
    }

    func encode<T: Encodable>(_ value: T) throws -> Data { try encoder.encode(value) }
    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T { try decoder.decode(type, from: data) }

    func decodeMeeting(_ row: Row) -> Meeting {
        Meeting(
            id: row["id"], title: row["title"],
            startedAt: Date(timeIntervalSince1970: row["started_at"]),
            endedAt: (row["ended_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
            state: MeetingState(rawValue: row["state"])!, language: row["language"],
            sourceName: row["source_name"], usesEchoCancellation: row["uses_echo_cancellation"],
            transcriptRevision: row["transcript_revision"],
            speechModel: SpeechRecognitionModel(rawValue: row["speech_model"]) ?? .whisper,
            recordingMode: RecordingMode(rawValue: row["recording_mode"]) ?? .online
        )
    }

    func decodeChunk(_ row: Row) -> CapturedChunk {
        CapturedChunk(
            id: row["id"], meetingID: row["meeting_id"], epochID: row["epoch_id"],
            track: AudioTrack(rawValue: row["track"])!, relativePath: row["relative_path"],
            startTime: row["start_time"], duration: row["duration"], sampleRate: row["sample_rate"],
            frameCount: row["frame_count"], sha256: row["sha256"]
        )
    }

    func decodeGap(_ row: Row) -> CaptureGap {
        CaptureGap(
            id: row["id"], meetingID: row["meeting_id"], startTime: row["start_time"],
            endTime: row["end_time"], reason: row["reason"]
        )
    }

    func decodeSegment(_ row: Row) -> TranscriptSegment {
        var segment = TranscriptSegment(
            id: row["id"], meetingID: row["meeting_id"], windowID: row["window_id"],
            track: AudioTrack(rawValue: row["track"])!, startTime: row["start_time"],
            endTime: row["end_time"], text: row["text"], speakerID: row["speaker_id"],
            isUncertain: row["is_uncertain"], isProvisional: row["is_provisional"],
            isEdited: row["is_edited"]
        )
        if let data: Data = row["review_json"], let metadata = try? JSONDecoder().decode(SegmentReviewMetadata.self, from: data) {
            segment.words = metadata.words; segment.recognitionEvidence = metadata.evidence
        }
        return segment
    }

    func decodeSpeaker(_ row: Row) -> Speaker {
        Speaker(
            id: row["id"], meetingID: row["meeting_id"], label: row["label"],
            isVerified: row["is_verified"]
        )
    }

    func decodeScreenshot(_ row: Row) -> ScreenshotRecord {
        ScreenshotRecord(
            id: row["id"], meetingID: row["meeting_id"], relativePath: row["relative_path"],
            capturedAt: row["captured_at"], perceptualHash: row["perceptual_hash"],
            interpretation: row["interpretation"]
        )
    }

    func decodeNotes(_ row: Row) throws -> MeetingNotes {
        var notes = MeetingNotes(
            id: row["id"], meetingID: row["meeting_id"],
            createdAt: Date(timeIntervalSince1970: row["created_at"]),
            transcriptRevision: row["transcript_revision"],
            summary: try decode([NoteItem].self, from: row["summary_json"]),
            decisions: try decode([NoteItem].self, from: row["decisions_json"]),
            actionItems: try decode([NoteItem].self, from: row["action_items_json"]),
            isEdited: row["is_edited"], isPartial: row["is_partial"]
        )
        if let data: Data = row["provenance_json"], let provenance = try? decode(NotesProvenance.self, from: data) {
            notes.model = provenance.model; notes.transcriptVersionID = provenance.transcriptVersionID
        }
        return notes
    }

    func decodeJob(_ row: Row) -> ProcessingJob {
        ProcessingJob(
            id: row["id"], meetingID: row["meeting_id"], kind: JobKind(rawValue: row["kind"])!,
            status: JobStatus(rawValue: row["status"])!, payload: row["payload"],
            attempts: row["attempts"], error: row["error"],
            createdAt: Date(timeIntervalSince1970: row["created_at"])
        )
    }

    func meetingArguments(_ meeting: Meeting) -> StatementArguments {
        [
            meeting.id, meeting.title, meeting.startedAt.timeIntervalSince1970,
            meeting.endedAt?.timeIntervalSince1970, meeting.state.rawValue, meeting.language,
            meeting.sourceName, meeting.usesEchoCancellation, meeting.transcriptRevision, meeting.recognitionModel.rawValue, meeting.recordingMode.rawValue,
        ]
    }

    func segmentArguments(_ segment: TranscriptSegment) -> StatementArguments {
        [
            segment.meetingID, segment.id, segment.windowID, segment.track.rawValue,
            segment.startTime, segment.endTime, segment.text, segment.speakerID,
            segment.isUncertain, segment.isProvisional, segment.isEdited,
        ]
    }

    func jobArguments(_ job: ProcessingJob) -> StatementArguments {
        [
            job.meetingID, job.id, job.kind.rawValue, job.status.rawValue, job.payload,
            job.attempts, job.error, job.createdAt.timeIntervalSince1970,
        ]
    }

    func replaceFTSRow(_ db: Database, segment: TranscriptSegment) throws {
        let metadata = try encode(SegmentReviewMetadata(words: segment.words, evidence: segment.recognitionEvidence))
        try db.execute(sql: "UPDATE transcript_segments SET review_json = ? WHERE meeting_id = ? AND id = ?", arguments: [metadata, segment.meetingID, segment.id])
        try db.execute(
            sql: "DELETE FROM segment_fts WHERE meeting_id = ? AND segment_id = ?",
            arguments: [segment.meetingID, segment.id]
        )
        try db.execute(
            sql: "INSERT INTO segment_fts (meeting_id, segment_id, text) VALUES (?, ?, ?)",
            arguments: [segment.meetingID, segment.id, segment.text]
        )
    }

    func prettyEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

struct ExportSnapshot: Codable, Sendable {
    let meeting: Meeting
    let chunks: [CapturedChunk]
    let gaps: [CaptureGap]
    let segments: [TranscriptSegment]
    let speakers: [Speaker]
    let screenshots: [ScreenshotRecord]
    let notes: [MeetingNotes]
    let jobs: [ProcessingJob]
    var transcriptVersion: String? = nil
    var annotations: [TranscriptAnnotation] = []
    var speakerGrouping: [SpeakerGroupingRun]? = nil
}

private enum DeletionState: String {
    case prepared
    case completed
    case cancelled
}

private struct DeletionTombstone: Codable {
    let meeting: Meeting
    let deletedAt: Date
    let chunks: [CapturedChunk]
    let screenshots: [ScreenshotRecord]
}

private struct SegmentRevisionSignature: Equatable {
    let id: String
    let text: String
    let isEdited: Bool
    let isProvisional: Bool

    init(_ segment: TranscriptSegment) {
        id = segment.id
        text = segment.text
        isEdited = segment.isEdited
        isProvisional = segment.isProvisional
    }

    init(id: String, text: String, isEdited: Bool, isProvisional: Bool) {
        self.id = id
        self.text = text
        self.isEdited = isEdited
        self.isProvisional = isProvisional
    }
}
