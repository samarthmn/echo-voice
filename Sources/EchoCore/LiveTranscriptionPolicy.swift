import Foundation
import GRDB

public struct LiveTranscriptionPolicy: Codable, Sendable, Equatable {
    public let enabledAtStart: Bool
    public let stoppedAt: Double?

    public init(enabledAtStart: Bool, stoppedAt: Double? = nil) {
        self.enabledAtStart = enabledAtStart
        self.stoppedAt = stoppedAt
    }

    public var admitsLiveRecognition: Bool { enabledAtStart && stoppedAt == nil }
}

extension MeetingStore {
    /// Older meetings retain the historical live-recognition default.
    public func liveTranscriptionPolicy(meetingID: String) throws -> LiveTranscriptionPolicy {
        try database.read { db in
            if let payload = try Data.fetchOne(db, sql: "SELECT payload FROM live_transcription_policy WHERE meeting_id=?", arguments: [meetingID]) {
                return try decode(LiveTranscriptionPolicy.self, from: payload)
            }
            guard try Int.fetchOne(db, sql: "SELECT 1 FROM meetings WHERE id=?", arguments: [meetingID]) != nil else {
                throw EchoCoreError.meetingNotFound(meetingID)
            }
            return LiveTranscriptionPolicy(enabledAtStart: true)
        }
    }

    /// Write once, before capture begins. Resume never changes this choice.
    public func setInitialLiveTranscriptionPolicy(meetingID: String, enabled: Bool) throws {
        guard AppPaths.isSafeIdentifier(meetingID) else { throw EchoCoreError.invalidValue("live transcription policy") }
        let policy = LiveTranscriptionPolicy(enabledAtStart: enabled)
        try database.write { db in
            if let existing = try Data.fetchOne(db, sql: "SELECT payload FROM live_transcription_policy WHERE meeting_id=?", arguments: [meetingID]) {
                guard try decode(LiveTranscriptionPolicy.self, from: existing) == policy else {
                    throw EchoCoreError.invalidValue("live transcription choice cannot change after recording starts")
                }
                return
            }
            try db.execute(sql: "INSERT INTO live_transcription_policy(meeting_id,payload) VALUES (?,?)",
                           arguments: [meetingID, try encode(policy)])
        }
    }

    /// The first stop wins. Persist it before the caller acknowledges the action.
    @discardableResult public func stopLiveTranscription(meetingID: String, effectiveTime: Double) throws -> Double {
        guard AppPaths.isSafeIdentifier(meetingID), effectiveTime.isFinite, effectiveTime >= 0 else {
            throw EchoCoreError.invalidValue("live transcription stop time")
        }
        return try database.write { db in
            let payload = try Data.fetchOne(db, sql: "SELECT payload FROM live_transcription_policy WHERE meeting_id=?", arguments: [meetingID])
            if payload == nil, try Int.fetchOne(db, sql: "SELECT 1 FROM meetings WHERE id=?", arguments: [meetingID]) == nil {
                throw EchoCoreError.meetingNotFound(meetingID)
            }
            let policy = try payload.map { try decode(LiveTranscriptionPolicy.self, from: $0) }
                ?? LiveTranscriptionPolicy(enabledAtStart: true)
            guard policy.enabledAtStart else { throw EchoCoreError.invalidValue("live transcription was not enabled for this meeting") }
            if let stoppedAt = policy.stoppedAt { return stoppedAt }
            let updated = LiveTranscriptionPolicy(enabledAtStart: true, stoppedAt: effectiveTime)
            try db.execute(sql: "INSERT INTO live_transcription_policy(meeting_id,payload) VALUES (?,?) ON CONFLICT(meeting_id) DO UPDATE SET payload=excluded.payload",
                           arguments: [meetingID, try encode(updated)])
            return effectiveTime
        }
    }
}
