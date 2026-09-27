import Foundation
import AVFoundation
import CryptoKit
import EchoCore

public struct AssembledAudio: Sendable {
    public let url: URL
    public let relativePath: String
    public let startTime: Double
    public let frameCount: Int64
    public let coveredFrames: Int64
    public let sha256: String
    public var duration: Double { Double(frameCount) / 16000 }
    public var isFullyCovered: Bool { frameCount - coveredFrames <= 1 }
}
public enum AudioAssemblyError: LocalizedError {
    case invalidRange, invalidChunk(String), missingReference, emptyAudio
    public var errorDescription: String? {
        switch self {
        case .invalidRange: return "Audio processing windows must be finite, positive, and at most 30 seconds."
        case .invalidChunk(let path): return "Saved audio is inconsistent or unreadable: \(path). The raw recording has been preserved."
        case .missingReference: return "Echo cancellation needs matching microphone and selected-app audio. Missing reference audio was not replaced with silence."
        case .emptyAudio: return "There is no recorded audio in this range."
        }
    }
}

/// Reads at most one native chunk and produces at most 30 seconds of 16kHz mono.
/// Each native chunk's host timestamp determines placement. A next host timestamp
/// within 50ms corrects clock drift by stretching that chunk, rather than assuming
/// the microphone and playback devices have identical sample clocks.
public struct AudioWindowAssembler: Sendable {
    public let paths: AppPaths
    private let audioAssets: AudioAssetStore?
    public init(paths: AppPaths, audioAssets: AudioAssetStore? = nil) { self.paths = paths; self.audioAssets = audioAssets }
    public func assemble(meetingID: String, chunks: [CapturedChunk], start: Double, duration: Double, relativePath: String) throws -> AssembledAudio {
        let audio = try samples(meetingID: meetingID, chunks: chunks, start: start, duration: duration)
        let url = try paths.resolveMeetingAsset(meetingID: meetingID, relativePath: relativePath)
        let writer = try PCM16WaveWriter(url: url)
        try writer.append(audio.samples)
        try writer.finish()
        return AssembledAudio(url: url, relativePath: relativePath, startTime: start, frameCount: Int64(audio.samples.count), coveredFrames: Int64(audio.covered), sha256: try Self.digest(url))
    }
    public func emptyWave(meetingID: String, relativePath: String) throws -> URL {
        let url = try paths.resolveMeetingAsset(meetingID: meetingID, relativePath: relativePath)
        let writer = try PCM16WaveWriter(url: url); try writer.finish(); return url
    }
    /// Full meeting output remains bounded in memory. Real recording gaps retain
    /// their timeline positions as silence; this export is never an AEC reference.
    public func assembleFull(meetingID: String, chunks: [CapturedChunk], relativePath: String) throws -> URL {
        guard let end = chunks.map({ $0.startTime + $0.duration }).max(), end > 0 else { throw AudioAssemblyError.emptyAudio }
        let url = try paths.resolveMeetingAsset(meetingID: meetingID, relativePath: relativePath)
        let writer = try PCM16WaveWriter(url: url)
        var start = 0.0
        while start < end {
            try Task.checkCancellation()
            let duration = min(30, end - start)
            let audio = try samples(meetingID: meetingID, chunks: chunks, start: start, duration: duration)
            try writer.append(audio.samples); start += duration
        }
        try writer.finish(); return url
    }
    private func samples(meetingID: String, chunks: [CapturedChunk], start: Double, duration: Double) throws -> (samples: [Float], covered: Int) {
        guard start.isFinite, start >= 0, duration.isFinite, duration > 0, duration <= 30.00001 else { throw AudioAssemblyError.invalidRange }
        let count = Int((duration * 16000).rounded())
        guard count > 0 else { throw AudioAssemblyError.invalidRange }
        var output = [Float](repeating: 0, count: count)
        var coverage = [UInt8](repeating: 0, count: count)
        let ordered = chunks.sorted { $0.startTime < $1.startTime }
        for (index, chunk) in ordered.enumerated() {
            guard chunk.meetingID == meetingID, chunk.startTime.isFinite, chunk.duration.isFinite, chunk.duration > 0, chunk.duration <= 30.1 else { throw AudioAssemblyError.invalidChunk(chunk.relativePath) }
            var hostDuration = chunk.duration
            if index + 1 < ordered.count {
                let next = ordered[index + 1]
                let corrected = next.startTime - chunk.startTime
                if next.epochID == chunk.epochID, next.track == chunk.track, corrected > 0, abs(corrected - chunk.duration) <= 0.05 { hostDuration = corrected }
            }
            let overlapStart = max(start, chunk.startTime)
            let overlapEnd = min(start + duration, chunk.startTime + hostDuration)
            guard overlapEnd > overlapStart else { continue }
            let lease = try audioAssets?.acquireSync(chunk: chunk)
            let url = try lease?.url ?? paths.resolveMeetingAsset(meetingID: meetingID, relativePath: chunk.relativePath)
            guard try Self.digest(url) == chunk.sha256 else { throw AudioAssemblyError.invalidChunk(chunk.relativePath) }
            let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard file.length == chunk.frameCount, file.length > 0, file.length <= Int64(file.processingFormat.sampleRate * 30.1), abs(file.processingFormat.sampleRate - chunk.sampleRate) < 1 else { throw AudioAssemblyError.invalidChunk(chunk.relativePath) }
            guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
                  let monoFormat = AVAudioFormat(standardFormatWithSampleRate: file.processingFormat.sampleRate, channels: 1),
                  let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(file.length)),
                  let target = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1),
                  let converter = AVAudioConverter(from: monoFormat, to: target),
                  let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(ceil(Double(file.length) * 16000 / file.processingFormat.sampleRate)) + 64) else { throw AudioAssemblyError.invalidChunk(chunk.relativePath) }
            try file.read(into: input)
            guard let channels = input.floatChannelData, let destination = mono.floatChannelData?[0] else { throw AudioAssemblyError.invalidChunk(chunk.relativePath) }
            mono.frameLength = input.frameLength
            // Explicit equal-weight mono mix includes every source channel. The
            // converter's default downmix=false may select only one channel.
            // Bounding each input and averaging in Double provides deterministic
            // headroom without clipping when channels contain full-scale audio.
            for frame in 0..<Int(input.frameLength) {
                var sum = 0.0
                for channel in 0..<Int(input.format.channelCount) {
                    let sample = Double(channels[channel][frame])
                    if sample.isFinite { sum += min(1, max(-1, sample)) }
                }
                destination[frame] = Float(sum / Double(input.format.channelCount))
            }
            var supplied = false
            var conversionError: NSError?
            let status = converter.convert(to: converted, error: &conversionError) { _, state in
                if supplied { state.pointee = .endOfStream; return nil }
                supplied = true; state.pointee = .haveData; return mono
            }
            if let conversionError { throw conversionError }
            guard status != .error, converted.frameLength > 0, let source = converted.floatChannelData?[0] else { throw AudioAssemblyError.invalidChunk(chunk.relativePath) }
            let first = max(0, Int(((overlapStart - start) * 16000).rounded()))
            let last = min(count, Int(((overlapEnd - start) * 16000).rounded()))
            if first >= last { continue }
            let frames = Int(converted.frameLength)
            for frame in first..<last {
                let hostTime = start + Double(frame) / 16000
                let position = max(0, min(Double(frames - 1), (hostTime - chunk.startTime) / hostDuration * Double(frames)))
                let lower = Int(position), upper = min(lower + 1, frames - 1)
                let fraction = Float(position - Double(lower))
                let value = source[lower] * (1 - fraction) + source[upper] * fraction
                output[frame] = value.isFinite ? value : 0
                coverage[frame] = 1
            }
        }
        return (output, coverage.reduce(0) { $0 + Int($1) })
    }
    public static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty { hash.update(data: bytes) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private final class PCM16WaveWriter {
    private let url: URL
    private let partial: URL
    private var handle: FileHandle?
    private var frames: UInt64 = 0
    init(url: URL) throws {
        self.url = url; partial = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).partial")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: partial.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        handle = try FileHandle(forWritingTo: partial)
        try handle?.write(contentsOf: Self.header(byteCount: 0))
    }
    func append(_ samples: [Float]) throws {
        guard frames + UInt64(samples.count) <= UInt64(UInt32.max - 36) / 2 else { throw AudioAssemblyError.invalidRange }
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            var value = Int16(max(-32768, min(32767, Int((Double(sample) * 32768).rounded())))).littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        try handle?.write(contentsOf: data); frames += UInt64(samples.count)
    }
    func finish() throws {
        guard let handle else { return }
        try handle.seek(toOffset: 0); try handle.write(contentsOf: Self.header(byteCount: UInt32(frames * 2)))
        try handle.synchronize(); try handle.close(); self.handle = nil
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try FileManager.default.moveItem(at: partial, to: url)
    }
    deinit { try? handle?.close(); try? FileManager.default.removeItem(at: partial) }
    private static func header(byteCount: UInt32) -> Data {
        var data = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        append(byteCount + 36); data.append(Data("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(16000)); append(UInt32(32000)); append(UInt16(2)); append(UInt16(16)); data.append(Data("data".utf8)); append(byteCount)
        return data
    }
}
