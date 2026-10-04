import Foundation
import GRDB

public struct QueuedProcessing: Sendable, Equatable, Identifiable {
    public var id: String { meetingID }
    public let meetingID: String
    public let windowedSpeakers: Bool
    public let waitingForModels: Bool
}

extension MeetingStore {
    /// Stopping capture and persisting the post-processing intent is one transaction.
    public func queueFinishedRecording(meetingID: String, endedAt: Date) throws {
        try requireDeletionRecovered(meetingID: meetingID)
        try database.write { db in
            try db.execute(sql: "UPDATE meetings SET state = ?, ended_at = ? WHERE id = ?",
                           arguments: [MeetingState.finalizing.rawValue, endedAt.timeIntervalSince1970, meetingID])
            try db.execute(sql: "INSERT INTO processing_queue(meeting_id) VALUES (?) ON CONFLICT(meeting_id) DO NOTHING",
                           arguments: [meetingID])
        }
    }

    /// Keep the original FIFO position when an explicit retry updates its options.
    public func enqueueProcessing(meetingID: String, windowedSpeakers: Bool = false) throws {
        try requireDeletionRecovered(meetingID: meetingID)
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO processing_queue(meeting_id, windowed_speakers) VALUES (?, ?)
                ON CONFLICT(meeting_id) DO UPDATE SET windowed_speakers = excluded.windowed_speakers, waiting_models = 0
                """, arguments: [meetingID, windowedSpeakers])
        }
    }
    public func processingQueue() throws -> [QueuedProcessing] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT meeting_id, windowed_speakers, waiting_models FROM processing_queue ORDER BY sequence").map {
                QueuedProcessing(meetingID: $0["meeting_id"], windowedSpeakers: $0["windowed_speakers"], waitingForModels: $0["waiting_models"])
            }
        }
    }
    public func waitForProcessingModels(meetingID: String) throws {
        try database.write { db in
            try db.execute(sql: "UPDATE processing_queue SET waiting_models = 1 WHERE meeting_id = ?", arguments: [meetingID])
        }
    }
    public func finishQueuedProcessing(meetingID: String) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM processing_queue WHERE meeting_id = ?", arguments: [meetingID])
        }
    }
}

public struct ActionAvailability: Equatable, Sendable {
    public let reason: String?
    public var isEnabled: Bool { reason == nil }
    public init(reason: String? = nil) { self.reason = reason }
}

public struct ProcessingEvent: Equatable, Sendable {
    public enum Stage: String, Sendable { case queued, preparing, transcribing, speakers, notes, ready, needsAttention }
    public let meetingID: String
    public let stage: Stage
    public let message: String
    public let completed: Int?
    public let total: Int?
    public init(meetingID: String, stage: Stage, message: String, completed: Int? = nil, total: Int? = nil) {
        self.meetingID = meetingID; self.stage = stage; self.message = message
        self.completed = completed; self.total = total
    }
}

/// A single resolution rule for scheduling and execution of reviewed transcript work.
public struct FinalizationContext: Sendable {
    public let activeVersionID: String
    public let configuration: ProcessingConfiguration?
    public let reusesTranscript: Bool
}

extension MeetingStore {
    public func finalizationContext(meetingID: String) throws -> FinalizationContext {
        let activeID = try activeTranscriptVersion(meetingID: meetingID)
        let active = try transcriptVersions(meetingID: meetingID).first { $0.id == activeID }
        let reuse = try active?.status == .ready || canReuseTranscriptAfterRedaction(meetingID: meetingID)
        return FinalizationContext(activeVersionID: activeID,
            configuration: try active?.configuration ?? configuration(meetingID: meetingID), reusesTranscript: reuse)
    }
}
