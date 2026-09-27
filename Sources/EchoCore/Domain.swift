import Foundation

public enum MeetingState: String, Codable, Sendable, CaseIterable {
    case recording
    case paused
    case interrupted
    case finalizing
    case ready
    case failed
}

public enum AudioTrack: String, Codable, Sendable, CaseIterable {
    case microphone
    case remote
    case cleanMicrophone
}

public enum JobKind: String, Codable, Sendable, CaseIterable {
    case prepareAudio
    case transcribe
    case diarize
    case vision
    case notes
}

public enum JobStatus: String, Codable, Sendable, CaseIterable {
    case pending
    case running
    case completed
    case failed
    case cancelled
}

public enum SpeechRecognitionModel: String, Codable, Sendable, CaseIterable {
    case whisper, parakeet
    public var displayName: String {
        switch self {
        case .whisper: return "Whisper large-v3-turbo"
        case .parakeet: return "Parakeet Unified English 0.6B"
        }
    }
    public var assetKey: String { self == .whisper ? "asr" : "parakeet" }
}

public enum RecordingMode: String, Codable, Sendable, CaseIterable {
    case online, inPerson
    public var displayName: String { self == .online ? "Online meeting" : "In person" }
    public var groupingTrack: AudioTrack { self == .inPerson ? .microphone : .remote }
    public var microphoneLabel: String { self == .inPerson ? "Room microphone" : "Your microphone" }
}

public struct Meeting: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var title: String
    public var startedAt: Date
    public var endedAt: Date?
    public var state: MeetingState
    public var language: String
    public var sourceName: String
    public var usesEchoCancellation: Bool
    public var transcriptRevision: Int
    public var speechModel: SpeechRecognitionModel?
    public var recordingMode: RecordingMode
    public var recognitionModel: SpeechRecognitionModel { speechModel ?? .whisper }

    public init(
        id: String,
        title: String,
        startedAt: Date,
        endedAt: Date?,
        state: MeetingState,
        language: String,
        sourceName: String,
        usesEchoCancellation: Bool,
        transcriptRevision: Int,
        speechModel: SpeechRecognitionModel = .whisper,
        recordingMode: RecordingMode = .online
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.state = state
        self.language = language
        self.sourceName = sourceName
        self.usesEchoCancellation = usesEchoCancellation
        self.transcriptRevision = transcriptRevision
        self.speechModel = speechModel
        self.recordingMode = recordingMode
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, startedAt, endedAt, state, language, sourceName, usesEchoCancellation, transcriptRevision, speechModel, recordingMode
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); title = try c.decode(String.self, forKey: .title)
        startedAt = try c.decode(Date.self, forKey: .startedAt); endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        state = try c.decode(MeetingState.self, forKey: .state); language = try c.decode(String.self, forKey: .language)
        sourceName = try c.decode(String.self, forKey: .sourceName)
        usesEchoCancellation = try c.decode(Bool.self, forKey: .usesEchoCancellation)
        transcriptRevision = try c.decode(Int.self, forKey: .transcriptRevision)
        speechModel = try c.decodeIfPresent(SpeechRecognitionModel.self, forKey: .speechModel)
        recordingMode = try c.decodeIfPresent(RecordingMode.self, forKey: .recordingMode) ?? .online
    }
}

public struct CapturedChunk: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var meetingID: String
    public var epochID: String
    public var track: AudioTrack
    public var relativePath: String
    public var startTime: Double
    public var duration: Double
    public var sampleRate: Double
    public var frameCount: Int64
    public var sha256: String

    public init(
        id: String,
        meetingID: String,
        epochID: String,
        track: AudioTrack,
        relativePath: String,
        startTime: Double,
        duration: Double,
        sampleRate: Double,
        frameCount: Int64,
        sha256: String
    ) {
        self.id = id
        self.meetingID = meetingID
        self.epochID = epochID
        self.track = track
        self.relativePath = relativePath
        self.startTime = startTime
        self.duration = duration
        self.sampleRate = sampleRate
        self.frameCount = frameCount
        self.sha256 = sha256
    }
}

/// Durable intent written before an unfinished raw CAF receives any frames.
/// It is not a verified CapturedChunk: recovery retains its bytes and records an
/// explicit gap until a finalized, checksummed chunk can be committed.
public struct CaptureChunkIntent: Codable, Sendable {
    public var id: String
    public var meetingID: String
    public var epochID: String
    public var track: AudioTrack
    public var relativePath: String
    public var startTime: Double
    public var sampleRate: Double
    public var channels: UInt32
    public init(id: String, meetingID: String, epochID: String, track: AudioTrack, relativePath: String, startTime: Double, sampleRate: Double, channels: UInt32) {
        self.id = id; self.meetingID = meetingID; self.epochID = epochID; self.track = track
        self.relativePath = relativePath; self.startTime = startTime; self.sampleRate = sampleRate; self.channels = channels
    }
}

public struct CaptureGap: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var meetingID: String
    public var startTime: Double
    public var endTime: Double?
    public var reason: String

    public init(id: String, meetingID: String, startTime: Double, endTime: Double?, reason: String) {
        self.id = id
        self.meetingID = meetingID
        self.startTime = startTime
        self.endTime = endTime
        self.reason = reason
    }
}

public struct TranscriptSegment: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var meetingID: String
    public var windowID: String
    public var track: AudioTrack
    public var startTime: Double
    public var endTime: Double
    public var text: String
    public var speakerID: String?
    public var isUncertain: Bool
    public var isProvisional: Bool
    public var isEdited: Bool
    public var words: [TranscriptWord]?
    public var recognitionEvidence: RecognitionEvidence?

    public init(
        id: String,
        meetingID: String,
        windowID: String,
        track: AudioTrack,
        startTime: Double,
        endTime: Double,
        text: String,
        speakerID: String?,
        isUncertain: Bool,
        isProvisional: Bool,
        isEdited: Bool,
        words: [TranscriptWord]? = nil,
        recognitionEvidence: RecognitionEvidence? = nil
    ) {
        self.id = id
        self.meetingID = meetingID
        self.windowID = windowID
        self.track = track
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.speakerID = speakerID
        self.isUncertain = isUncertain
        self.isProvisional = isProvisional
        self.isEdited = isEdited
        self.words = words; self.recognitionEvidence = recognitionEvidence
    }
}

public struct Speaker: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var meetingID: String
    public var label: String
    public var isVerified: Bool

    public init(id: String, meetingID: String, label: String, isVerified: Bool) {
        self.id = id
        self.meetingID = meetingID
        self.label = label
        self.isVerified = isVerified
    }
}

public struct ScreenshotRecord: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var meetingID: String
    public var relativePath: String
    public var capturedAt: Double
    public var perceptualHash: String
    public var interpretation: String?

    public init(
        id: String,
        meetingID: String,
        relativePath: String,
        capturedAt: Double,
        perceptualHash: String,
        interpretation: String?
    ) {
        self.id = id
        self.meetingID = meetingID
        self.relativePath = relativePath
        self.capturedAt = capturedAt
        self.perceptualHash = perceptualHash
        self.interpretation = interpretation
    }
}

public struct NoteItem: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var text: String
    public var evidenceIDs: [String]
    public var owner: String?
    public var dueDate: String?
    public var evidenceRemoved: Bool?

    public init(id: String, text: String, evidenceIDs: [String], owner: String? = nil, dueDate: String? = nil) {
        self.id = id
        self.text = text
        self.evidenceIDs = evidenceIDs
        self.owner = owner
        self.dueDate = dueDate
    }
}

public struct MeetingNotes: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var meetingID: String
    public var createdAt: Date
    public var transcriptRevision: Int
    public var summary: [NoteItem]
    public var decisions: [NoteItem]
    public var actionItems: [NoteItem]
    public var isEdited: Bool
    public var isPartial: Bool
    public var model: ModelSelection?
    public var transcriptVersionID: String?

    public init(
        id: String,
        meetingID: String,
        createdAt: Date,
        transcriptRevision: Int,
        summary: [NoteItem],
        decisions: [NoteItem],
        actionItems: [NoteItem],
        isEdited: Bool,
        isPartial: Bool
    ) {
        self.id = id
        self.meetingID = meetingID
        self.createdAt = createdAt
        self.transcriptRevision = transcriptRevision
        self.summary = summary
        self.decisions = decisions
        self.actionItems = actionItems
        self.isEdited = isEdited
        self.isPartial = isPartial
    }
}

public struct ProcessingJob: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var meetingID: String
    public var kind: JobKind
    public var status: JobStatus
    public var payload: String
    public var attempts: Int
    public var error: String?
    public var createdAt: Date

    public init(
        id: String,
        meetingID: String,
        kind: JobKind,
        status: JobStatus,
        payload: String,
        attempts: Int,
        error: String?,
        createdAt: Date
    ) {
        self.id = id
        self.meetingID = meetingID
        self.kind = kind
        self.status = status
        self.payload = payload
        self.attempts = attempts
        self.error = error
        self.createdAt = createdAt
    }
}

public struct SearchHit: Codable, Sendable, Equatable {
    public var segment: TranscriptSegment
    public var meetingTitle: String

    public init(segment: TranscriptSegment, meetingTitle: String) {
        self.segment = segment
        self.meetingTitle = meetingTitle
    }
}

public enum EchoCoreError: Error, Sendable, Equatable, LocalizedError {
    case invalidIdentifier(String)
    case invalidRelativePath(String)
    case assetMissing(String)
    case assetNotRegularFile(String)
    case meetingNotFound(String)
    case recordNotFound(String)
    case ambiguousIdentifier(String)
    case invalidValue(String)
    case staleTranscriptRevision
    case checksumMismatch(String)
    case deletionRecoveryRequired(String)
    case deletionPurgeRequired(String)

    public var errorDescription: String? {
        switch self {
        case .invalidIdentifier(let value): return "Invalid identifier: \(value)"
        case .invalidRelativePath(let value): return "Invalid relative path: \(value)"
        case .assetMissing(let value): return "Asset is missing: \(value)"
        case .assetNotRegularFile(let value): return "Asset is not a regular file: \(value)"
        case .meetingNotFound(let value): return "Meeting not found: \(value)"
        case .recordNotFound(let value): return "Record not found: \(value)"
        case .ambiguousIdentifier(let value): return "Identifier is ambiguous across meetings: \(value)"
        case .invalidValue(let value): return "Invalid value: \(value)"
        case .staleTranscriptRevision: return "The transcript changed while this page was loading."
        case .checksumMismatch(let value): return "Asset checksum does not match recovery metadata: \(value)"
        case .deletionRecoveryRequired(let value): return "Deletion could not be rolled back safely; assets remain at: \(value)"
        case .deletionPurgeRequired(let value): return "Deletion was committed, but media cleanup must be retried at: \(value)"
        }
    }
}

public enum LibraryRecovery {
    public static func message(root: URL, reason: String) -> String {
        "Echo Voice could not open its library at \(root.path). Nothing was deleted. Quit Echo Voice, move that folder aside, and open the app again. The original problem was: \(reason)"
    }
}
