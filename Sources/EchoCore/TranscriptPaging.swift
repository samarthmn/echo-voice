import Foundation
import GRDB

public struct TranscriptRowIdentity: Sendable, Equatable, Identifiable {
    public let id: String
    public let startTime: Double
    public let endTime: Double
    public let track: AudioTrack
    public let isProvisional: Bool
}

public struct TranscriptTimelineSnapshot: Sendable {
    public let rows: [TranscriptRowIdentity]
    public let transcriptRevision: Int
    public init(rows: [TranscriptRowIdentity], transcriptRevision: Int) {
        self.rows = rows; self.transcriptRevision = transcriptRevision
    }
}

public struct TranscriptPageRequest: Sendable {
    public enum Direction: Sendable { case forward, backward }
    public let meetingID: String
    public let versionID: String
    /// An exclusive segment ID cursor. `nil` starts at the first or last row.
    public let anchor: String?
    public let direction: Direction
    public let limit: Int
    public let expectedRevision: Int?

    public init(meetingID: String, versionID: String, anchor: String?, direction: Direction,
                limit: Int = 200, expectedRevision: Int? = nil) {
        self.meetingID = meetingID
        self.versionID = versionID
        self.anchor = anchor
        self.direction = direction
        self.limit = limit
        self.expectedRevision = expectedRevision
    }
}

public struct TranscriptPage: Sendable {
    public let rows: [TranscriptSegment]
    public let precedingCursor: String?
    public let followingCursor: String?
    public let transcriptRevision: Int
}

public protocol TranscriptPageSource: Sendable {
    func transcriptRowIdentities(meetingID: String, versionID: String) throws -> [TranscriptRowIdentity]
    func transcriptTimeline(meetingID: String, versionID: String) throws -> TranscriptTimelineSnapshot
    func transcriptPage(_ request: TranscriptPageRequest) throws -> TranscriptPage
}

public extension TranscriptPageSource {
    func transcriptTimeline(meetingID: String, versionID: String) throws -> TranscriptTimelineSnapshot {
        try TranscriptTimelineSnapshot(rows: transcriptRowIdentities(meetingID: meetingID, versionID: versionID),
                                       transcriptRevision: 0)
    }
}

extension MeetingStore: TranscriptPageSource {
    public func availableTracks(meetingID: String) throws -> Set<AudioTrack> {
        try database.read { db in
            try Set(String.fetchAll(db, sql: "SELECT DISTINCT track FROM chunks WHERE meeting_id=?", arguments: [meetingID]).map { value in
                guard let track = AudioTrack(rawValue: value) else { throw EchoCoreError.invalidValue("audio track") }
                return track
            })
        }
    }

    /// Lightweight timeline for table virtualization; word and text payloads stay on disk.
    public func transcriptRowIdentities(meetingID: String, versionID: String) throws -> [TranscriptRowIdentity] {
        try transcriptTimeline(meetingID: meetingID, versionID: versionID).rows
    }

    public func transcriptTimeline(meetingID: String, versionID: String) throws -> TranscriptTimelineSnapshot {
        try database.read { db in
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM meetings WHERE id=?)", arguments: [meetingID]) == true else {
                throw EchoCoreError.meetingNotFound(meetingID)
            }
            let revision = try Int.fetchOne(db, sql: "SELECT transcript_revision FROM meetings WHERE id=?", arguments: [meetingID]) ?? 0
            if try activeVersion(db, meetingID: meetingID) == versionID {
                let rows = try Row.fetchAll(db, sql: "SELECT id,start_time,end_time,track,is_provisional FROM transcript_segments WHERE meeting_id=? ORDER BY start_time,end_time,id", arguments: [meetingID]).map {
                    let track: String = $0["track"]
                    guard let track = AudioTrack(rawValue: track) else { throw EchoCoreError.invalidValue("transcript track") }
                    return TranscriptRowIdentity(id: $0["id"], startTime: $0["start_time"], endTime: $0["end_time"], track: track, isProvisional: $0["is_provisional"])
                }
                return TranscriptTimelineSnapshot(rows: rows, transcriptRevision: revision)
            }
            try requireVersion(db, meetingID: meetingID, versionID: versionID)
            let rows = try Row.fetchAll(db, sql: "SELECT id,start_time,json_extract(payload,'$.endTime') AS end_time,json_extract(payload,'$.track') AS track,json_extract(payload,'$.isProvisional') AS is_provisional FROM version_segments WHERE version_id=? ORDER BY start_time,end_time,id", arguments: [versionID]).map {
                let track: String = $0["track"]
                guard let track = AudioTrack(rawValue: track) else { throw EchoCoreError.invalidValue("transcript track") }
                let provisional: Bool = $0["is_provisional"]
                return TranscriptRowIdentity(id: $0["id"], startTime: $0["start_time"], endTime: $0["end_time"], track: track, isProvisional: provisional)
            }
            return TranscriptTimelineSnapshot(rows: rows, transcriptRevision: revision)
        }
    }

    public func segment(meetingID: String, versionID: String, segmentID: String) throws -> TranscriptSegment? {
        try database.read { db in
            if try activeVersion(db, meetingID: meetingID) == versionID {
                return try Row.fetchOne(db, sql: "SELECT * FROM transcript_segments WHERE meeting_id=? AND id=?", arguments: [meetingID, segmentID]).map(decodeSegment)
            }
            try requireVersion(db, meetingID: meetingID, versionID: versionID)
            return try Data.fetchOne(db, sql: "SELECT payload FROM version_segments WHERE version_id=? AND id=?", arguments: [versionID, segmentID]).map { try decode(TranscriptSegment.self, from: $0) }
        }
    }

    public func transcriptPage(_ request: TranscriptPageRequest) throws -> TranscriptPage {
        let limit = max(1, min(request.limit, 200))
        return try database.read { db in
            let revision = try Int.fetchOne(db, sql: "SELECT transcript_revision FROM meetings WHERE id=?", arguments: [request.meetingID])
            guard let revision else { throw EchoCoreError.meetingNotFound(request.meetingID) }
            if let expected = request.expectedRevision, expected != revision {
                throw EchoCoreError.staleTranscriptRevision
            }
            let current = try activeVersion(db, meetingID: request.meetingID)
            let isActive = current == request.versionID
            if !isActive { try requireVersion(db, meetingID: request.meetingID, versionID: request.versionID) }
            let table = isActive ? "transcript_segments" : "version_segments"
            let scope = isActive ? "meeting_id" : "version_id"
            let end = isActive ? "end_time" : "json_extract(payload,'$.endTime')"
            let order = request.direction == .forward ? "ASC" : "DESC"
            let comparison = request.direction == .forward ? ">" : "<"
            var arguments: StatementArguments = [isActive ? request.meetingID : request.versionID]
            var cursorClause = ""
            if let anchor = request.anchor {
                let cursor = try Row.fetchOne(db,
                    sql: "SELECT start_time,\(end) AS end_time,id FROM \(table) WHERE \(scope)=? AND id=?",
                    arguments: [isActive ? request.meetingID : request.versionID, anchor])
                guard let cursor else { throw EchoCoreError.invalidValue("transcript page cursor") }
                cursorClause = " AND (start_time,\(end),id) \(comparison) (?,?,?)"
                arguments += [cursor["start_time"] as Double, cursor["end_time"] as Double, anchor]
            }
            arguments += [limit + 1]
            let projection = isActive ? "*" : "payload"
            let rows = try Row.fetchAll(db,
                sql: "SELECT \(projection) FROM \(table) WHERE \(scope)=?\(cursorClause) ORDER BY start_time \(order),\(end) \(order),id \(order) LIMIT ?",
                arguments: arguments)
            let hasMore = rows.count > limit
            let bounded = Array(rows.prefix(limit))
            let decoded: [TranscriptSegment] = try bounded.map { row in
                if isActive { return decodeSegment(row) }
                let payload: Data = row["payload"]
                return try decode(TranscriptSegment.self, from: payload)
            }
            let ordered = request.direction == .backward ? Array(decoded.reversed()) : decoded
            let preceding = request.direction == .backward && hasMore ? ordered.first?.id : nil
            let following = request.direction == .forward && hasMore ? ordered.last?.id : nil
            return TranscriptPage(rows: ordered, precedingCursor: preceding, followingCursor: following, transcriptRevision: revision)
        }
    }

    private func activeVersion(_ db: Database, meetingID: String) throws -> String {
        try String.fetchOne(db, sql: "SELECT active_version FROM meeting_configuration WHERE meeting_id=?", arguments: [meetingID]) ?? "legacy-" + meetingID
    }

    private func requireVersion(_ db: Database, meetingID: String, versionID: String) throws {
        guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM transcript_versions WHERE id=? AND meeting_id=?)", arguments: [versionID, meetingID]) == true else {
            throw EchoCoreError.invalidValue("transcript version")
        }
    }
}
