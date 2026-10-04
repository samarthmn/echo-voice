import AVFoundation
import EchoCore

/// Advance by the requested time interval, not by its rounded sample count.
/// A sub-sample tail must reach the end rather than repeatedly schedule zero frames.
struct PlaybackBufferWindow {
    let start: Double
    let end: Double
    var duration: Double { end - start }
    init?(start: Double, end: Double) {
        guard start.isFinite, end.isFinite, start >= 0, end > start else { return nil }
        self.start = start
        self.end = min(start + 2, end)
    }
}

/// File access and conversion never run on the main actor or the audio render callback.
private actor PlaybackBuffers {
    let directory: URL
    let chunks: [CapturedChunk]
    let audioAssets: AudioAssetStore?
    private var cache: [String: AVAudioPCMBuffer] = [:]
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    init(directory: URL, chunks: [CapturedChunk], audioAssets: AudioAssetStore?) {
        self.directory = directory; self.chunks = chunks; self.audioAssets = audioAssets
    }
    func buffer(start: Double, duration: Double) throws -> AVAudioPCMBuffer {
        let count = AVAudioFrameCount((duration * 48_000).rounded())
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count), let destination = output.floatChannelData?[0] else { throw PlaybackError.invalidAudio }
        output.frameLength = count
        destination.initialize(repeating: 0, count: Int(count))
        let relevant = chunks.filter { $0.startTime < start + duration && $0.startTime + $0.duration > start }
        let audibleTracks = Set(chunks.map(\.track)).count
        // Equal gain prevents two full-scale sources from clipping without changing originals.
        let gain: Float = audibleTracks > 1 ? 0.5 : 1
        for chunk in relevant {
            try Task.checkCancellation()
            let input: AVAudioPCMBuffer
            if let cached = cache[chunk.id] { input = cached }
            else {
                let lease = try audioAssets?.acquireSync(chunk: chunk)
                let file = try AVAudioFile(forReading: lease?.url ?? directory.appendingPathComponent(chunk.relativePath))
                guard file.length > 0, file.length <= AVAudioFramePosition(file.processingFormat.sampleRate * 15),
                      let raw = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { throw PlaybackError.invalidAudio }
                try file.read(into: raw)
                guard let converter = AVAudioConverter(from: file.processingFormat, to: format),
                      let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(ceil(Double(raw.frameLength) / file.processingFormat.sampleRate * 48_000)) + 256) else { throw PlaybackError.invalidAudio }
                var supplied = false; var conversionError: NSError?
                let result = converter.convert(to: converted, error: &conversionError) { _, state in
                    if supplied { state.pointee = .endOfStream; return nil }
                    supplied = true; state.pointee = .haveData; return raw
                }
                guard conversionError == nil, result != .error, converted.frameLength > 0 else { throw conversionError ?? PlaybackError.invalidAudio as NSError }
                input = converted; cache[chunk.id] = converted
            }
            guard let samples = input.floatChannelData?[0], chunk.duration > 0 else { throw PlaybackError.invalidAudio }
            let lower = max(0, Int(ceil((chunk.startTime - start) * 48_000)))
            let upper = min(Int(count), Int(ceil((chunk.startTime + chunk.duration - start) * 48_000)))
            guard lower < upper else { continue }
            // Follow the committed host-clock duration, including measured device drift.
            let framesPerSecond = Double(input.frameLength) / chunk.duration
            for index in lower..<upper {
                let position = max(0, (start + Double(index) / 48_000 - chunk.startTime) * framesPerSecond)
                let left = min(Int(input.frameLength)-1, Int(position)), right = min(Int(input.frameLength)-1, left+1)
                let fraction = Float(position - Double(left))
                destination[index] += (samples[left] + (samples[right] - samples[left]) * fraction) * gain
            }
        }
        let keep = Set(relevant.map(\.id)); cache = cache.filter { keep.contains($0.key) }
        return output
    }
}
private enum PlaybackError: LocalizedError {
    case invalidAudio, underflow
    var errorDescription: String? { switch self { case .invalidAudio: "Saved audio could not be prepared for playback."; case .underflow: "Playback paused because audio could not be prepared in time. Press Play to continue." } }
}

@MainActor
final class MeetingPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let speed = AVAudioUnitTimePitch()
    private let buffers: PlaybackBuffers
    private var preparation: Task<Void, Never>?
    private var generation = UUID()
    private var seekTime = 0.0
    private var scheduledUntil = 0.0
    private var storedTime = 0.0
    private var started = false
    private var playbackEnd: Double?
    let duration: Double
    var onError: ((String) -> Void)?
    private(set) var isPlaying = false
    var rate: Float = 1 { didSet { speed.rate = rate } }
    var currentTime: Double {
        guard started, let render = node.lastRenderTime, let clock = node.playerTime(forNodeTime: render), clock.sampleRate > 0 else { return storedTime }
        return min(duration, seekTime + Double(clock.sampleTime) / clock.sampleRate)
    }
    init(directory: URL, chunks: [CapturedChunk], audioAssets: AudioAssetStore? = nil) throws {
        guard !chunks.isEmpty else { throw PlaybackError.invalidAudio }
        duration = chunks.map { $0.startTime + $0.duration }.max() ?? 0
        buffers = PlaybackBuffers(directory: directory, chunks: chunks.sorted { $0.startTime < $1.startTime }, audioAssets: audioAssets)
        engine.attach(node); engine.attach(speed)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        engine.connect(node, to: speed, format: format); engine.connect(speed, to: engine.mainMixerNode, format: format)
    }
    func play(at time: Double) throws {
        stop()
        playbackEnd = duration
        seekTime = max(0, min(time, duration)); storedTime = seekTime; scheduledUntil = seekTime
        guard seekTime < duration else { return }
        let token = UUID(); generation = token; isPlaying = true
        preparation = Task { [weak self] in
            guard let self else { return }
            do {
                while !Task.isCancelled, self.generation == token {
                    let end = self.playbackEnd ?? self.duration
                    if self.started && self.currentTime >= end - 0.015 { self.stop(); self.storedTime = end; return }
                    if self.started && self.currentTime > self.scheduledUntil + 0.01 { throw PlaybackError.underflow }
                    if self.scheduledUntil < end && self.scheduledUntil - self.currentTime < 12 {
                        guard let window = PlaybackBufferWindow(start: self.scheduledUntil, end: end) else { return }
                        let buffer = try await self.buffers.buffer(start: window.start, duration: window.duration)
                        try Task.checkCancellation(); guard self.generation == token else { return }
                        self.scheduledUntil = window.end
                        if buffer.frameLength > 0 { self.node.scheduleBuffer(buffer, completionHandler: nil) }
                        else if !self.started {
                            self.stop(); self.storedTime = end; return
                        }
                        if !self.started && (self.scheduledUntil - self.seekTime >= 6 || self.scheduledUntil >= end) {
                            try self.engine.start(); self.node.play(); self.started = true
                        }
                    } else { try await Task.sleep(nanoseconds: 50_000_000) }
                }
            } catch is CancellationError {} catch { self.stop(); self.onError?(error.localizedDescription) }
        }
    }
    func play(range: Range<Double>) throws {
        guard range.lowerBound.isFinite, range.upperBound.isFinite,
              range.lowerBound >= 0, range.upperBound > range.lowerBound,
              range.lowerBound < duration else { throw PlaybackError.invalidAudio }
        try play(at: range.lowerBound)
        playbackEnd = min(duration, range.upperBound)
    }
    func stop() {
        storedTime = currentTime; preparation?.cancel(); preparation = nil; generation = UUID()
        isPlaying = false; started = false; node.stop(); engine.stop()
    }
}
