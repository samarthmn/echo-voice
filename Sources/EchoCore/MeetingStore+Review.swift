import Foundation
import GRDB
import CryptoKit

struct NotesProvenance: Codable { var model: ModelSelection?; var transcriptVersionID: String? }
struct SegmentReviewMetadata: Codable { var words: [TranscriptWord]?; var evidence: RecognitionEvidence? }

extension MeetingStore {
    public func vocabulary() throws -> [VocabularyEntry] {
        try database.read { db in try Data.fetchAll(db,sql:"SELECT payload FROM vocabulary ORDER BY id").map { try decode(VocabularyEntry.self,from:$0) } }
    }
    public func saveVocabulary(_ entries: [VocabularyEntry]) throws {
        let validated=try VocabularyEntry.validated(entries)
        try database.write { db in
            try db.execute(sql:"DELETE FROM vocabulary")
            for entry in validated { try db.execute(sql:"INSERT INTO vocabulary(id,payload) VALUES (?,?)",arguments:[entry.id,try encode(entry)]) }
        }
    }
    public func preference<T: Decodable>(_ key: String, as type: T.Type) throws -> T? {
        try database.read { db in try Data.fetchOne(db,sql:"SELECT value FROM app_preferences WHERE key = ?",arguments:[key]).map { try decode(type,from:$0) } }
    }
    public func setPreference<T: Encodable>(_ key: String, value: T) throws {
        try database.write { db in try db.execute(sql:"INSERT INTO app_preferences(key,value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",arguments:[key,try encode(value)]) }
    }
    public func configuration(meetingID: String) throws -> ProcessingConfiguration? {
        try database.read { db in try Data.fetchOne(db,sql:"SELECT payload FROM meeting_configuration WHERE meeting_id = ?",arguments:[meetingID]).map { try decode(ProcessingConfiguration.self,from:$0) } }
    }
    public func setConfiguration(meetingID: String, configuration: ProcessingConfiguration) throws {
        try database.write { db in
            // Recording settings are immutable. Retrying setup must not replace them.
            if let existing=try Data.fetchOne(db,sql:"SELECT payload FROM meeting_configuration WHERE meeting_id=?",arguments:[meetingID]) {
                guard try decode(ProcessingConfiguration.self,from:existing)==configuration else { throw EchoCoreError.invalidValue("recording configuration is immutable") }
                return
            }
            try db.execute(sql:"INSERT INTO meeting_configuration(meeting_id,active_version,payload) VALUES (?,?,?) ON CONFLICT(meeting_id) DO UPDATE SET payload=excluded.payload",arguments:[meetingID,"legacy-"+meetingID,try encode(configuration)])
        }
    }
    public func activeTranscriptVersion(meetingID: String) throws -> String {
        try database.read { db in try String.fetchOne(db,sql:"SELECT active_version FROM meeting_configuration WHERE meeting_id=?",arguments:[meetingID]) ?? "legacy-"+meetingID }
    }
    public func transcriptVersions(meetingID: String) throws -> [TranscriptVersion] {
        try database.read { db in try Data.fetchAll(db,sql:"SELECT payload FROM transcript_versions WHERE meeting_id=? ORDER BY created_at DESC",arguments:[meetingID]).map { try decode(TranscriptVersion.self,from:$0) } }
    }
    public func saveTranscriptVersion(_ version: TranscriptVersion) throws {
        guard AppPaths.isSafeIdentifier(version.id),AppPaths.isSafeIdentifier(version.meetingID) else { throw EchoCoreError.invalidValue("transcript version") }
        try database.write { db in
            if let existing=try Row.fetchOne(db,sql:"SELECT meeting_id,payload FROM transcript_versions WHERE id=?",arguments:[version.id]) {
                let original=try decode(TranscriptVersion.self,from:existing["payload"])
                guard original.meetingID==version.meetingID,original.configuration==version.configuration,original.audioFingerprint==version.audioFingerprint else { throw EchoCoreError.invalidValue("immutable transcript identity") }
            }
            try db.execute(sql:"INSERT INTO transcript_versions(id,meeting_id,created_at,status,payload) VALUES (?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET status=excluded.status,payload=excluded.payload",arguments:[version.id,version.meetingID,version.createdAt.timeIntervalSince1970,version.status.rawValue,try encode(version)])
        }
    }
    public func saveVersionWindow(versionID: String, windowID: String, segments: [TranscriptSegment]) throws {
        try database.write { db in
            guard let row=try Row.fetchOne(db,sql:"SELECT meeting_id,status FROM transcript_versions WHERE id=?",arguments:[versionID]),row["status"] as String == "building" else { throw EchoCoreError.invalidValue("version is not being built") }
            let meetingID: String=row["meeting_id"]
            for segment in segments {
                try validate(segment)
                guard segment.meetingID==meetingID,segment.windowID==windowID,!segment.isProvisional else { throw EchoCoreError.invalidValue("version segment") }
            }
            try ensureOutsideRedactions(db, meetingID: meetingID, segments: segments)
            try db.execute(sql:"DELETE FROM version_segments WHERE version_id=? AND window_id=?",arguments:[versionID,windowID])
            for segment in segments { try db.execute(sql:"INSERT INTO version_segments(version_id,id,window_id,start_time,payload) VALUES (?,?,?,?,?)",arguments:[versionID,segment.id,windowID,segment.startTime,try encode(segment)]) }
        }
    }
    public func versionSegments(versionID: String) throws -> [TranscriptSegment] {
        try database.read { db in try Data.fetchAll(db,sql:"SELECT payload FROM version_segments WHERE version_id=? ORDER BY start_time,id",arguments:[versionID]).map { try decode(TranscriptSegment.self,from:$0) } }
    }
    public func versionSegments(versionID: String, windowIDs: [String]) throws -> [TranscriptSegment] {
        guard !windowIDs.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: windowIDs.count).joined(separator: ",")
        return try database.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM version_segments WHERE version_id=? AND window_id IN (\(placeholders)) ORDER BY start_time,id",
                              arguments: StatementArguments([versionID] + windowIDs))
                .map { try decode(TranscriptSegment.self, from: $0) }
        }
    }
    public func activateTranscriptVersion(_ versionID: String, meetingID: String) throws {
        try database.write { db in
            guard let target=try Row.fetchOne(db,sql:"SELECT payload FROM transcript_versions WHERE id=? AND meeting_id=? AND status='ready'",arguments:[versionID,meetingID]) else { throw EchoCoreError.invalidValue("transcript version is not ready") }
            let next=try decode(TranscriptVersion.self,from:target["payload"])
            let currentID=try String.fetchOne(db,sql:"SELECT active_version FROM meeting_configuration WHERE meeting_id=?",arguments:[meetingID]) ?? "legacy-"+meetingID
            if currentID==versionID { return }
            guard let meeting=try Row.fetchOne(db,sql:"SELECT * FROM meetings WHERE id=?",arguments:[meetingID]), !["recording","paused","interrupted"].contains(meeting["state"] as String) else { throw EchoCoreError.invalidValue("finish the recording before switching transcripts") }
            let oldConfiguration=try Data.fetchOne(db,sql:"SELECT payload FROM meeting_configuration WHERE meeting_id=?",arguments:[meetingID]).map { try decode(ProcessingConfiguration.self,from:$0) }
            let old=try Data.fetchOne(db,sql:"SELECT payload FROM transcript_versions WHERE id=?",arguments:[currentID]).map { try decode(TranscriptVersion.self,from:$0) } ?? TranscriptVersion(id:currentID,meetingID:meetingID,status:.ready,configuration:oldConfiguration,audioFingerprint:"legacy")
            try db.execute(sql:"INSERT INTO transcript_versions(id,meeting_id,created_at,status,payload) VALUES (?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload",arguments:[old.id,meetingID,old.createdAt.timeIntervalSince1970,old.status.rawValue,try encode(old)])
            let previous=try Row.fetchAll(db,sql:"SELECT * FROM transcript_segments WHERE meeting_id=?",arguments:[meetingID]).map(decodeSegment)
            try db.execute(sql:"DELETE FROM version_segments WHERE version_id=?",arguments:[currentID])
            for segment in previous { try db.execute(sql:"INSERT INTO version_segments(version_id,id,window_id,start_time,payload) VALUES (?,?,?,?,?)",arguments:[currentID,segment.id,segment.windowID,segment.startTime,try encode(segment)]) }
            let incoming=try Data.fetchAll(db,sql:"SELECT payload FROM version_segments WHERE version_id=? ORDER BY start_time,id",arguments:[versionID]).map { try decode(TranscriptSegment.self,from:$0) }
            try ensureOutsideRedactions(db, meetingID: meetingID, segments: incoming)
            try db.execute(sql:"DELETE FROM segment_fts WHERE meeting_id=?",arguments:[meetingID])
            try db.execute(sql:"DELETE FROM transcript_segments WHERE meeting_id=?",arguments:[meetingID])
            for segment in incoming {
                try db.execute(sql:"INSERT INTO transcript_segments(meeting_id,id,window_id,track,start_time,end_time,text,speaker_id,is_uncertain,is_provisional,is_edited) VALUES (?,?,?,?,?,?,?,?,?,?,?)",arguments:segmentArguments(segment))
                try replaceFTSRow(db,segment:segment)
            }
            let savedAnnotations = try Data.fetchAll(db, sql: "SELECT payload FROM transcript_annotations WHERE meeting_id=?", arguments: [meetingID]).map { try decode(TranscriptAnnotation.self, from: $0) }
            for annotation in savedAnnotations where annotation.kind == .highlight && annotation.transcriptVersionID == currentID {
                guard let quote = annotation.quote, !quote.isEmpty else { continue }
                var matches: [(TranscriptSegment, NSRange)] = []
                for segment in incoming where segment.track == annotation.track && segment.startTime < (annotation.endTime ?? annotation.startTime) && segment.endTime > annotation.startTime {
                    let text = segment.text as NSString
                    var cursor = 0
                    while cursor < text.length {
                        let range = text.range(of: quote, options: [], range: NSRange(location: cursor, length: text.length-cursor))
                        guard range.location != NSNotFound else { break }
                        matches.append((segment, range)); cursor = NSMaxRange(range)
                    }
                }
                guard matches.count == 1, let match = matches.first else { continue }
                var copy = annotation
                copy.id = SHA256.hash(data: Data((annotation.id + versionID).utf8)).map { String(format: "%02x", $0) }.joined()
                copy.transcriptVersionID = versionID; copy.segmentID = match.0.id; copy.location = match.1.location; copy.length = match.1.length
                try db.execute(sql: "INSERT OR IGNORE INTO transcript_annotations(id,meeting_id,start_time,payload) VALUES (?,?,?,?)", arguments: [copy.id, meetingID, copy.startTime, try encode(copy)])
            }
            try db.execute(sql:"INSERT INTO meeting_configuration(meeting_id,active_version,payload) VALUES (?,?,?) ON CONFLICT(meeting_id) DO UPDATE SET active_version=excluded.active_version,payload=excluded.payload",arguments:[meetingID,versionID,try next.configuration.map(encode)])
            try db.execute(sql:"UPDATE meetings SET transcript_revision=transcript_revision+1 WHERE id=?",arguments:[meetingID])
        }
    }
    public func annotations(meetingID: String) throws -> [TranscriptAnnotation] {
        try database.read { db in try Data.fetchAll(db,sql:"SELECT payload FROM transcript_annotations WHERE meeting_id=? ORDER BY start_time,id",arguments:[meetingID]).map { try decode(TranscriptAnnotation.self,from:$0) } }
    }
    public func saveAnnotation(_ annotation: TranscriptAnnotation) throws {
        guard AppPaths.isSafeIdentifier(annotation.id), AppPaths.isSafeIdentifier(annotation.meetingID),annotation.startTime.isFinite,annotation.startTime>=0,
              annotation.endTime.map({ $0.isFinite && $0>=annotation.startTime }) ?? true else { throw EchoCoreError.invalidValue("annotation timing") }
        if annotation.kind == .highlight {
            guard let location=annotation.location,let length=annotation.length,location>=0,length>0,annotation.quote?.isEmpty==false,annotation.segmentID != nil,annotation.transcriptVersionID != nil else { throw EchoCoreError.invalidValue("highlight") }
        }
        try database.write { db in
            if let existing=try String.fetchOne(db,sql:"SELECT meeting_id FROM transcript_annotations WHERE id=?",arguments:[annotation.id]),existing != annotation.meetingID { throw EchoCoreError.invalidValue("annotation identity") }
            try db.execute(sql:"INSERT INTO transcript_annotations(id,meeting_id,start_time,payload) VALUES (?,?,?,?) ON CONFLICT(id) DO UPDATE SET start_time=excluded.start_time,payload=excluded.payload",arguments:[annotation.id,annotation.meetingID,annotation.startTime,try encode(annotation)])
        }
    }
    public func removeAnnotation(id: String, meetingID: String) throws {
        try database.write { db in try db.execute(sql:"DELETE FROM transcript_annotations WHERE id=? AND meeting_id=?",arguments:[id,meetingID]) }
    }
    public func segments(meetingID: String, offset: Int, limit: Int = 300) throws -> [TranscriptSegment] {
        try database.read { db in try Row.fetchAll(db,sql:"SELECT * FROM transcript_segments WHERE meeting_id=? ORDER BY start_time,end_time,id LIMIT ? OFFSET ?",arguments:[meetingID,max(1,min(limit,1000)),max(0,offset)]).map(decodeSegment) }
    }
}
