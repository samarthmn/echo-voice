import Foundation
import GRDB

public enum CaptureAcousticMode: String, Codable, Sendable, Hashable {
    case headphones, speakerphone
}

public struct CaptureSessionSettings: Codable, Sendable, Equatable {
    public var microphoneUID: String?
    public var applicationID: String?
    public var microphoneMuted: Bool
    public var acousticMode: CaptureAcousticMode

    public init(microphoneUID: String?, applicationID: String?, microphoneMuted: Bool,
                acousticMode: CaptureAcousticMode) {
        self.microphoneUID = microphoneUID
        self.applicationID = applicationID
        self.microphoneMuted = microphoneMuted
        self.acousticMode = acousticMode
    }

    private enum CodingKeys: String, CodingKey { case microphoneUID, applicationID, microphoneMuted, acousticMode }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        microphoneUID = try values.decodeIfPresent(String.self, forKey: .microphoneUID)
        applicationID = try values.decodeIfPresent(String.self, forKey: .applicationID)
        microphoneMuted = try values.decodeIfPresent(Bool.self, forKey: .microphoneMuted) ?? false
        acousticMode = try values.decodeIfPresent(CaptureAcousticMode.self, forKey: .acousticMode) ?? .headphones
    }
}

public enum CaptureResumePolicy {
    /// A resumed capture adds new epochs; it must not reinterpret the mode of
    /// audio already saved in earlier epochs.
    public static func validate(meeting: Meeting, saved: CaptureSessionSettings,
                                mode: RecordingMode, applicationID: String?,
                                microphoneUID: String?, acousticMode: CaptureAcousticMode) throws -> CaptureSessionSettings {
        guard meeting.recordingMode == mode,
              (mode != .inPerson || (applicationID == nil && microphoneUID != nil)),
              (acousticMode != .speakerphone || (applicationID != nil && microphoneUID != nil)) else {
            throw EchoCoreError.invalidValue("choose compatible inputs for this recording mode")
        }
        return CaptureSessionSettings(microphoneUID: microphoneUID, applicationID: applicationID,
                                      microphoneMuted: saved.microphoneMuted, acousticMode: acousticMode)
    }
}

public struct CaptureTrackEvent: Codable, Sendable, Equatable, Identifiable {
    public enum Cause: String, Codable, Sendable {
        case userMute, deviceUnavailable, sourceChanged, interruption, recovery
    }
    public var id: String
    public var meetingID: String
    public var track: AudioTrack
    public var startTime: Double
    public var endTime: Double?
    public var cause: Cause
    public var epochID: String?

    public init(id: String = UUID().uuidString, meetingID: String, track: AudioTrack,
                startTime: Double, endTime: Double?, cause: Cause, epochID: String?) {
        self.id = id; self.meetingID = meetingID; self.track = track
        self.startTime = startTime; self.endTime = endTime; self.cause = cause; self.epochID = epochID
    }
}

public struct MicrophoneProcessingEpoch: Codable, Sendable, Equatable {
    public var meetingID: String
    public var epochID: String
    public var startTime: Double
    public var sampleRate: Double
    public var channels: UInt32
    public var acousticMode: CaptureAcousticMode

    public init(meetingID: String, epochID: String, startTime: Double, sampleRate: Double,
                channels: UInt32, acousticMode: CaptureAcousticMode) {
        self.meetingID = meetingID; self.epochID = epochID; self.startTime = startTime
        self.sampleRate = sampleRate; self.channels = channels; self.acousticMode = acousticMode
    }
}

extension MeetingStore {
    public func captureSessionSettings(meetingID: String) throws -> CaptureSessionSettings {
        try database.read { db in
            if let payload = try Data.fetchOne(db, sql: "SELECT payload FROM capture_session_settings WHERE meeting_id=?", arguments: [meetingID]) {
                return try decode(CaptureSessionSettings.self, from: payload)
            }
            guard let usesAEC = try Bool.fetchOne(db, sql: "SELECT uses_echo_cancellation FROM meetings WHERE id=?", arguments: [meetingID]) else {
                throw EchoCoreError.meetingNotFound(meetingID)
            }
            return CaptureSessionSettings(microphoneUID: nil, applicationID: nil, microphoneMuted: false,
                                          acousticMode: usesAEC ? .speakerphone : .headphones)
        }
    }

    public func setCaptureSessionSettings(meetingID: String, settings: CaptureSessionSettings) throws {
        guard AppPaths.isSafeIdentifier(meetingID),
              settings.microphoneUID?.isEmpty != true,
              settings.applicationID?.isEmpty != true else { throw EchoCoreError.invalidValue("capture settings") }
        guard settings.acousticMode != .speakerphone || (settings.microphoneUID != nil && settings.applicationID != nil) else {
            throw EchoCoreError.invalidValue("Speakerphone processing requires a selected microphone and meeting application")
        }
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO capture_session_settings(meeting_id,payload) VALUES (?,?)
                ON CONFLICT(meeting_id) DO UPDATE SET payload=excluded.payload
                """, arguments: [meetingID, try encode(settings)])
        }
    }

    public func saveCaptureTrackEvent(_ event: CaptureTrackEvent) throws {
        guard AppPaths.isSafeIdentifier(event.id), AppPaths.isSafeIdentifier(event.meetingID),
              event.startTime.isFinite, event.startTime >= 0,
              event.endTime.map({ $0.isFinite && $0 >= event.startTime }) ?? true else {
            throw EchoCoreError.invalidValue("capture track event")
        }
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO capture_track_events(meeting_id,id,track,start_time,end_time,cause,epoch_id,payload)
                VALUES (?,?,?,?,?,?,?,?)
                ON CONFLICT(meeting_id,id) DO UPDATE SET end_time=excluded.end_time,payload=excluded.payload
                """, arguments: [event.meetingID, event.id, event.track.rawValue,
                                   event.startTime, event.endTime, event.cause.rawValue,
                                   event.epochID, try encode(event)])
        }
    }

    public func captureTrackEvents(meetingID: String) throws -> [CaptureTrackEvent] {
        try database.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM capture_track_events WHERE meeting_id=? ORDER BY start_time,id", arguments: [meetingID])
                .map { try decode(CaptureTrackEvent.self, from: $0) }
        }
    }

    public func saveMicrophoneProcessingEpoch(_ epoch: MicrophoneProcessingEpoch) throws {
        guard AppPaths.isSafeIdentifier(epoch.meetingID), AppPaths.isSafeIdentifier(epoch.epochID),
              epoch.startTime.isFinite, epoch.startTime >= 0,
              epoch.sampleRate.isFinite, epoch.sampleRate > 0, epoch.channels > 0 else {
            throw EchoCoreError.invalidValue("microphone processing epoch")
        }
        try database.write { db in
            if let existing = try Data.fetchOne(db, sql: "SELECT payload FROM microphone_processing_epochs WHERE meeting_id=? AND epoch_id=?", arguments: [epoch.meetingID, epoch.epochID]) {
                guard try decode(MicrophoneProcessingEpoch.self, from: existing) == epoch else {
                    throw EchoCoreError.invalidValue("microphone processing epoch is immutable")
                }
                return
            }
            try db.execute(sql: "INSERT INTO microphone_processing_epochs(meeting_id,epoch_id,start_time,acoustic_mode,payload) VALUES (?,?,?,?,?)",
                           arguments: [epoch.meetingID, epoch.epochID, epoch.startTime, epoch.acousticMode.rawValue, try encode(epoch)])
        }
    }

    public func microphoneProcessingEpochs(meetingID: String) throws -> [MicrophoneProcessingEpoch] {
        try database.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM microphone_processing_epochs WHERE meeting_id=? ORDER BY start_time,epoch_id", arguments: [meetingID])
                .map { try decode(MicrophoneProcessingEpoch.self, from: $0) }
        }
    }

    public func microphoneProcessingEpoch(meetingID: String, epochID: String) throws -> MicrophoneProcessingEpoch? {
        try database.read { db in
            try Data.fetchOne(db, sql: "SELECT payload FROM microphone_processing_epochs WHERE meeting_id=? AND epoch_id=?", arguments: [meetingID, epochID])
                .map { try decode(MicrophoneProcessingEpoch.self, from: $0) }
        }
    }

    public func acousticMode(meetingID: String, epochID: String) throws -> CaptureAcousticMode {
        try database.read { db in
            if let value = try String.fetchOne(db, sql: "SELECT acoustic_mode FROM microphone_processing_epochs WHERE meeting_id=? AND epoch_id=?", arguments: [meetingID, epochID]),
               let mode = CaptureAcousticMode(rawValue: value) { return mode }
            guard let legacy = try Bool.fetchOne(db, sql: "SELECT uses_echo_cancellation FROM meetings WHERE id=?", arguments: [meetingID]) else {
                throw EchoCoreError.meetingNotFound(meetingID)
            }
            return legacy ? .speakerphone : .headphones
        }
    }

    public func microphoneTranscriptChunks(meetingID: String) throws -> [CapturedChunk] {
        let chunks = try self.chunks(meetingID: meetingID)
        let modes = Dictionary(uniqueKeysWithValues: try microphoneProcessingEpochs(meetingID: meetingID).map { ($0.epochID, $0.acousticMode) })
        guard let meeting = try meeting(id: meetingID) else { throw EchoCoreError.meetingNotFound(meetingID) }
        let legacyMode: CaptureAcousticMode = meeting.usesEchoCancellation ? .speakerphone : .headphones
        return chunks.filter { chunk in
            let mode = modes[chunk.epochID] ?? legacyMode
            return (chunk.track == .microphone && mode == .headphones)
                || (chunk.track == .cleanMicrophone && mode == .speakerphone)
        }
    }

    public func speakerphoneMicrophoneChunks(meetingID: String) throws -> [CapturedChunk] {
        let modes = Dictionary(uniqueKeysWithValues: try microphoneProcessingEpochs(meetingID: meetingID).map { ($0.epochID, $0.acousticMode) })
        guard let meeting = try meeting(id: meetingID) else { throw EchoCoreError.meetingNotFound(meetingID) }
        let legacyMode: CaptureAcousticMode = meeting.usesEchoCancellation ? .speakerphone : .headphones
        return try chunks(meetingID: meetingID, track: .microphone).filter { (modes[$0.epochID] ?? legacyMode) == .speakerphone }
    }
}
