import Foundation
import EchoCore

public struct AudioSource: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let bundleID: String?
    public let processIDs: [Int32]
    public init(id: String, name: String, bundleID: String?, processIDs: [Int32]) {
        self.id = id; self.name = name; self.bundleID = bundleID; self.processIDs = processIDs
    }
}
public struct MicrophoneDevice: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let deviceID: UInt32
    public let isBuiltIn: Bool
    public let isDefault: Bool
    public init(id: String, name: String, deviceID: UInt32, isBuiltIn: Bool = false, isDefault: Bool = false) { self.id = id; self.name = name; self.deviceID = deviceID; self.isBuiltIn = isBuiltIn; self.isDefault = isDefault }
}
public struct CaptureConfiguration: Sendable {
    public let meetingID: String
    public let meetingDirectory: URL
    public let application: AudioSource?
    public let microphone: MicrophoneDevice?
    public let allowSingleSource: Bool
    public let initialOffset: Double
    public let expectedFormats: [CaptureAudioFormat]?
    public let recordingMode: RecordingMode
    public let initialMicrophoneMuted: Bool
    private let formatPreflight: (@Sendable ([CaptureAudioFormat]) throws -> Void)?
    public init(meetingID: String, meetingDirectory: URL, application: AudioSource?, microphone: MicrophoneDevice?, allowSingleSource: Bool, initialOffset: Double = 0, expectedFormats: [CaptureAudioFormat]? = nil, recordingMode: RecordingMode = .online, initialMicrophoneMuted: Bool = false, formatPreflight: (@Sendable ([CaptureAudioFormat]) throws -> Void)? = nil) {
        self.meetingID = meetingID; self.meetingDirectory = meetingDirectory; self.application = application
        self.microphone = microphone; self.allowSingleSource = allowSingleSource; self.initialOffset = initialOffset; self.expectedFormats = expectedFormats; self.formatPreflight = formatPreflight
        self.recordingMode = recordingMode
        self.initialMicrophoneMuted = initialMicrophoneMuted
    }
    public func runFormatPreflight(_ formats: [CaptureAudioFormat]) throws { try formatPreflight?(formats) }
}
public enum CaptureEvent: Sendable {
    case chunk(CapturedChunk), level(AudioTrack, Float), gap(CaptureGap), trackEvent(CaptureTrackEvent), interrupted(String), lowDisk(Int64), sourceChanged(String), trackChanged(AudioTrack, String)
}
public enum CaptureError: LocalizedError {
    case invalidConfiguration, permission(String), sourceUnavailable, unsupportedFormat, formatChanged, audio(String, Int32), diskFull, screenshot(String)
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "Select both audio sources, or explicitly enable single-source recording."
        case .permission(let detail): return detail
        case .sourceUnavailable: return "The selected audio source is no longer available. Select it again before resuming."
        case .formatChanged: return "An audio format changed after Test Inputs. Stop this attempt and test the selected inputs again before recording or resuming."
        case .unsupportedFormat: return "The selected device uses an unsupported audio format."
        case .audio(let operation, let status): return "\(operation) failed (Core Audio \(status))."
        case .diskFull: return "Recording stopped safely because less than 1 GB of disk space remains."
        case .screenshot(let detail): return detail
        }
    }
}
struct CaptureTimeline: Sendable {
    let originSeconds: Double
    let initialOffset: Double
    func time(hostSeconds: Double) -> Double { max(0, initialOffset + hostSeconds - originSeconds) }
}
struct TrackContinuity {
    private(set) var expected: Double?
    mutating func observe(start: Double, frames: Int, sampleRate: Double) -> Bool {
        let discontinuity = expected.map { abs(start - $0) > 0.05 } ?? false
        expected = start + Double(frames) / sampleRate
        return discontinuity
    }
}
struct ChunkFramePlan {
    let capacity: Int
    private(set) var count = 0
    init(sampleRate: Double) { capacity = max(1, Int((sampleRate * 5).rounded())) }
    var isFull: Bool { count == capacity }
    mutating func take(available: Int) -> Int { let n = min(available, capacity - count); count += n; return n }
    mutating func reset() { count = 0 }
}
struct ScreenshotDeduplicator {
    private var previous: [String: UInt64] = [:]
    mutating func shouldSave(hash: UInt64, scope: String) -> Bool {
        if let last = previous[scope], (last ^ hash).nonzeroBitCount <= 3 { return false }
        previous[scope] = hash
        return true
    }
    mutating func reset() { previous.removeAll() }
}

/// The actual capture format; canonical CAF storage always uses Float32 samples.
public struct CaptureAudioFormat: Sendable, Equatable {
    public let track: AudioTrack
    public let sampleRate: Double
    public let channels: UInt32
    public init(track: AudioTrack, sampleRate: Double, channels: UInt32) {
        self.track = track; self.sampleRate = sampleRate; self.channels = channels
    }
}

public struct CaptureStorageEstimate: Sendable {
    public let rawBytes: Int64
    public let processingBytes: Int64
    public let reserveBytes: Int64
    public var requiredBytes: Int64 { rawBytes + processingBytes + reserveBytes }

    public static func calculate(formats: [CaptureAudioFormat], echoCancellation: Bool, duration: Double = 28_800, reserveBytes: Int64 = 4_000_000_000) throws -> CaptureStorageEstimate {
        guard duration.isFinite, duration > 0, duration <= 28_800, reserveBytes >= 0,
              !formats.isEmpty, Set(formats.map(\.track)).count == formats.count,
              formats.allSatisfy({ ($0.track == .microphone || $0.track == .remote) && $0.sampleRate.isFinite && $0.sampleRate > 0 && $0.channels > 0 }) else { throw CaptureError.unsupportedFormat }
        let remote = formats.contains { $0.track == .remote }
        let microphone = formats.contains { $0.track == .microphone }
        guard !echoCancellation || (remote && microphone) else { throw CaptureError.invalidConfiguration }
        let raw = formats.reduce(0.0) { $0 + $1.sampleRate * Double($1.channels) * 4 * duration }
        // Retain AEC near + far replay inputs and clean output, all PCM16/16k mono.
        let aec = echoCancellation ? duration * 16_000 * 2 * 3 : 0
        let fullRemote = remote ? duration * 16_000 * 2 : 0
        // Conservatively allow every bounded ASR input to remain after failures,
        // including overlapping context, although successful windows are deleted.
        let asr = ceil(duration / 28) * 30 * 16_000 * 2 * Double(formats.count)
        let chunkFiles = Double(formats.count + (echoCancellation ? 6 : 0))
        let metadataAndHeaders = ceil(duration / 5) * chunkFiles * 4096
        let processing = aec + fullRemote + asr + metadataAndHeaders
        let maximum = Double(Int64.max) / 2
        guard raw.isFinite, processing.isFinite, raw < maximum, processing < maximum,
              raw + processing + Double(reserveBytes) < maximum else { throw CaptureError.unsupportedFormat }
        return CaptureStorageEstimate(rawBytes: Int64(ceil(raw)), processingBytes: Int64(ceil(processing)), reserveBytes: reserveBytes)
    }
}

/// Silence delivered as real buffers is active audio. Only a missing established
/// stream is stalled; the selected app may legitimately not have begun output.
enum AudioSourceLiveness: Equatable {
    case active, waitingForFirstAudio, stalled
    static func evaluate(track: AudioTrack, lastEnd: Double?, now: Double, startedAt: Double) -> AudioSourceLiveness {
        if track == .remote && lastEnd == nil { return .waitingForFirstAudio }
        return now - (lastEnd ?? startedAt) > 3 ? .stalled : .active
    }
}

/// Match the tested/preflight format before starting either device. Input tests
/// omit the expectation; real recording retains it across every resumed epoch.
enum CaptureFormatValidation {
    static func verify(actual: [CaptureAudioFormat], expected: [CaptureAudioFormat]?) throws {
        guard let expected else { return }
        guard !expected.isEmpty, expected.count == actual.count,
              Set(expected.map(\.track)).count == expected.count,
              Set(actual.map(\.track)).count == actual.count,
              expected.allSatisfy({ expectedFormat in actual.contains(expectedFormat) }) else { throw CaptureError.formatChanged }
    }
}
