import Foundation
import AVFoundation
import CryptoKit
import Darwin
import EchoCore

/// Confined to the recording worker queue; all conversion and disk I/O happen here.
final class AudioChunkWriter {
    let track: AudioTrack
    let configuration: CaptureConfiguration
    let format: AVAudioFormat
    private let converter: AVAudioConverter
    private var file: AVAudioFile?
    private var partialURL: URL?
    private var chunkID: String?
    private var startTime = 0.0
    private var epochID = ""
    private var plan: ChunkFramePlan
    private let publicationCheckpoint: @Sendable () throws -> Void
    private let onEvent: @Sendable (CaptureEvent) -> Void
    init(
        track: AudioTrack,
        inputFormat: AVAudioFormat,
        configuration: CaptureConfiguration,
        publicationCheckpoint: @escaping @Sendable () throws -> Void = {},
        onEvent: @escaping @Sendable (CaptureEvent) -> Void
    ) throws {
        self.track = track
        self.configuration = configuration
        self.publicationCheckpoint = publicationCheckpoint
        self.onEvent = onEvent
        // The channels-only initializer rejects more than two channels. Preserve
        // hardware layout where available, otherwise explicitly describe discrete
        // channels; raw capture must retain every selected-device channel.
        guard let layout = inputFormat.channelLayout ?? AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | inputFormat.channelCount),
              layout.channelCount == inputFormat.channelCount else { throw CaptureError.unsupportedFormat }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputFormat.sampleRate, interleaved: false, channelLayout: layout)
        guard let converter = AVAudioConverter(from: inputFormat, to: format) else { throw CaptureError.unsupportedFormat }
        self.format = format; self.converter = converter; plan = ChunkFramePlan(sampleRate: format.sampleRate)
        try FileManager.default.createDirectory(at: configuration.meetingDirectory.appendingPathComponent("audio"), withIntermediateDirectories: true)
    }
    func append(_ input: AVAudioPCMBuffer, at time: Double, epoch: String) throws -> Float {
        guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: input.frameLength) else { throw CaptureError.unsupportedFormat }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: converted, error: &conversionError) { _, outStatus in
            if supplied { outStatus.pointee = .noDataNow; return nil }
            supplied = true; outStatus.pointee = .haveData; return input
        }
        if let conversionError { throw conversionError }
        guard status != .error else { throw CaptureError.unsupportedFormat }
        var offset = 0
        var squared: Double = 0
        if let samples = converted.floatChannelData {
            for channel in 0..<Int(format.channelCount) {
                for frame in 0..<Int(converted.frameLength) { let value = Double(samples[channel][frame]); squared += value * value }
            }
        }
        while offset < Int(converted.frameLength) {
            if file == nil { try open(at: time + Double(offset) / format.sampleRate, epoch: epoch) }
            let amount = plan.take(available: Int(converted.frameLength) - offset)
            guard let piece = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(amount)), let from = converted.floatChannelData, let to = piece.floatChannelData else { throw CaptureError.unsupportedFormat }
            piece.frameLength = AVAudioFrameCount(amount)
            for channel in 0..<Int(format.channelCount) { memcpy(to[channel], from[channel].advanced(by: offset), amount * MemoryLayout<Float>.size) }
            try file?.write(from: piece)
            offset += amount
            if plan.isFull { try finish() }
        }
        return Float(sqrt(squared / Double(max(1, Int(converted.frameLength) * Int(format.channelCount)))))
    }
    private func open(at time: Double, epoch: String) throws {
        epochID = epoch
        startTime = time
        let id = UUID().uuidString
        let url = configuration.meetingDirectory.appendingPathComponent("audio/\(track.rawValue)-\(id).partial.caf")
        let completed = url.deletingPathExtension().deletingPathExtension().appendingPathExtension("caf")
        let intentURL = completed.appendingPathExtension("intent.json")
        let intent = CaptureChunkIntent(id: id, meetingID: configuration.meetingID, epochID: epoch, track: track, relativePath: "audio/" + completed.lastPathComponent, startTime: time, sampleRate: format.sampleRate, channels: format.channelCount)
        try JSONEncoder().encode(intent).write(to: intentURL, options: .atomic)
        try Self.sync(intentURL)
        Self.syncDirectory(intentURL.deletingLastPathComponent())
        var diskSettings = format.settings
        diskSettings[AVLinearPCMIsNonInterleaved] = false // CAF file layout; processing buffers remain planar
        let openedFile = try AVAudioFile(forWriting: url, settings: diskSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
        chunkID = id
        partialURL = url
        file = openedFile
    }
    func finish() throws {
        guard let partialURL, let chunkID else { return }
        file = nil // close CAF and write its final frame count before the durability barrier
        let frames = Int(try AVAudioFile(forReading: partialURL).length)
        guard frames > 0 else { throw CocoaError(.fileReadCorruptFile) }
        let fd = Darwin.open(partialURL.path, O_RDONLY)
        guard fd >= 0 else { throw CocoaError(.fileReadUnknown) }
        let synced = fsync(fd); Darwin.close(fd)
        guard synced == 0 else { throw CocoaError(.fileWriteUnknown) }
        let completed = partialURL.deletingPathExtension().deletingPathExtension().appendingPathExtension("caf")
        let handle = try FileHandle(forReadingFrom: partialURL)
        defer { try? handle.close() }
        var hash = SHA256()
        while let block = try handle.read(upToCount: 1024 * 1024), !block.isEmpty { hash.update(data: block) }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        let chunk = CapturedChunk(
            id: chunkID,
            meetingID: configuration.meetingID,
            epochID: epochID,
            track: track,
            relativePath: "audio/" + completed.lastPathComponent,
            startTime: startTime,
            duration: Double(frames) / format.sampleRate,
            sampleRate: format.sampleRate,
            frameCount: Int64(frames),
            sha256: digest
        )
        let sidecar = completed.appendingPathExtension("chunk.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(chunk).write(to: sidecar, options: .atomic)
        try Self.sync(sidecar)
        Self.syncDirectory(sidecar.deletingLastPathComponent())
        try publicationCheckpoint()
        try FileManager.default.moveItem(at: partialURL, to: completed)
        Self.syncDirectory(completed.deletingLastPathComponent())
        onEvent(.chunk(chunk))
        self.partialURL = nil
        self.chunkID = nil
        plan.reset()
    }

    private static func sync(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw CocoaError(.fileReadUnknown) }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func syncDirectory(_ url: URL) {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return }
        _ = fsync(descriptor)
        Darwin.close(descriptor)
    }
}

final class RecordingWorker: @unchecked Sendable {
    struct Track {
        let kind: AudioTrack
        let ring: RealtimeBufferQueue
        let scratch: AVAudioPCMBuffer
        let writer: AudioChunkWriter
        let epochID: String
        let activatedAt: Double
        var continuity = TrackContinuity()
        var waitingGap: CaptureGap?
    }
    let workQueue = DispatchQueue(label: "EchoVoice.audio.disk", qos: .userInitiated)
    private var tracks: [Track] = []
    private var timer: DispatchSourceTimer?
    private var epoch = UUID().uuidString
    private let configuration: CaptureConfiguration
    private let timeline: CaptureTimeline
    private let onEvent: @Sendable (CaptureEvent) -> Void
    private let onFailure: @Sendable (String, Double?) -> Void
    private let onTrackFailure: @Sendable (AudioTrack, String, Double?) -> Void
    private let startedAt = AVAudioTime.seconds(forHostTime: mach_absolute_time())
    private var failureTime: Double?
    private var failed = false
    private var lastLevel: [AudioTrack: Double] = [:]
    init(configuration: CaptureConfiguration, timeline: CaptureTimeline, sources: [(AudioTrack, RealtimeBufferQueue)], onEvent: @escaping @Sendable (CaptureEvent) -> Void, onFailure: @escaping @Sendable (String, Double?) -> Void, onTrackFailure: @escaping @Sendable (AudioTrack, String, Double?) -> Void = { _, _, _ in }) throws {
        self.configuration = configuration; self.timeline = timeline; self.onEvent = onEvent; self.onFailure = onFailure; self.onTrackFailure = onTrackFailure
        for (kind, ring) in sources {
            guard let scratch = AVAudioPCMBuffer(pcmFormat: ring.format, frameCapacity: ring.capacity) else { throw CaptureError.unsupportedFormat }
            tracks.append(Track(kind: kind, ring: ring, scratch: scratch, writer: try AudioChunkWriter(track: kind, inputFormat: ring.format, configuration: configuration, onEvent: onEvent), epochID: epoch, activatedAt: startedAt))
        }
    }
    func start() {
        workQueue.async { [self] in
            let timer = DispatchSource.makeTimerSource(queue: self.workQueue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in self?.drain() }
            self.timer = timer; timer.resume()
        }
    }
    private func drain() {
        guard !failed else { return }
        var index = 0
        while index < tracks.count {
            do {
                failureTime = nil
                try drainTrack(index)
                index += 1
            } catch {
                let track = tracks.remove(at: index)
                try? track.writer.finish()
                onTrackFailure(track.kind, error.localizedDescription, failureTime)
                if tracks.isEmpty {
                    failed = true
                    onFailure(error.localizedDescription, failureTime)
                    return
                }
            }
        }
    }

    private func drainTrack(_ index: Int) throws {
                for _ in 0..<64 {
                    guard let host = tracks[index].ring.pop(into: tracks[index].scratch) else { break }
                    let start = timeline.time(hostSeconds: AVAudioTime.seconds(forHostTime: host))
                    if tracks[index].kind == .microphone, tracks[index].ring.muteHostTime != 0 {
                        let muteTime = timeline.time(hostSeconds: AVAudioTime.seconds(forHostTime: tracks[index].ring.muteHostTime))
                        let allowed = Int(floor((muteTime - start) * tracks[index].ring.format.sampleRate))
                        if allowed <= 0 { continue }
                        tracks[index].scratch.frameLength = AVAudioFrameCount(min(allowed, Int(tracks[index].scratch.frameLength)))
                    }
                    let oldEnd = tracks[index].continuity.expected
                    if tracks[index].kind == .remote, oldEnd == nil {
                        let waitingStart = timeline.time(hostSeconds: tracks[index].activatedAt)
                        if let gap = tracks[index].waitingGap {
                            onEvent(.gap(CaptureGap(id: gap.id, meetingID: configuration.meetingID, startTime: min(gap.startTime, start), endTime: start, reason: gap.reason)))
                            tracks[index].waitingGap = nil
                        } else if start - waitingStart > 0.05 {
                            onEvent(.gap(CaptureGap(id: UUID().uuidString, meetingID: configuration.meetingID, startTime: waitingStart, endTime: start, reason: "Waiting for the selected application's first audio.")))
                        }
                    }
                    if tracks[index].continuity.observe(start: start, frames: Int(tracks[index].scratch.frameLength), sampleRate: tracks[index].ring.format.sampleRate) {
                        failureTime = min(oldEnd ?? start, start)
                        throw CaptureError.audio("\(tracks[index].kind.rawValue) host-clock discontinuity; resume to begin a new capture epoch", -1)
                    }
                    let rms = try tracks[index].writer.append(tracks[index].scratch, at: start, epoch: tracks[index].epochID)
                    if start - (lastLevel[tracks[index].kind] ?? -1) > 0.1 {
                        onEvent(.level(tracks[index].kind, rms)); lastLevel[tracks[index].kind] = start
                    }
                }
                let now = timeline.time(hostSeconds: AVAudioTime.seconds(forHostTime: mach_absolute_time()))
                let initial = timeline.time(hostSeconds: tracks[index].activatedAt)
                let last = tracks[index].continuity.expected ?? initial
                let liveness = AudioSourceLiveness.evaluate(track: tracks[index].kind, lastEnd: tracks[index].continuity.expected, now: now, startedAt: initial)
                if liveness == .waitingForFirstAudio, now - initial > 0.05, tracks[index].waitingGap == nil {
                    let gap = CaptureGap(id: UUID().uuidString, meetingID: configuration.meetingID, startTime: initial, endTime: nil, reason: "Waiting for the selected application's first audio.")
                    tracks[index].waitingGap = gap; onEvent(.gap(gap))
                }
                if tracks[index].kind == .microphone && tracks[index].ring.muteHostTime != 0 { return }
                if tracks[index].ring.hasDroppedAudio || liveness == .stalled {
                    failureTime = last
                    throw CaptureError.audio(tracks[index].ring.hasDroppedAudio ? "Audio buffer overflow; resume to begin a new capture epoch" : "The selected \(tracks[index].kind.rawValue) source stopped delivering audio", -1)
                }
    }
    func hasTrack(_ kind: AudioTrack) -> Bool {
        workQueue.sync { tracks.contains { $0.kind == kind } }
    }
    func closeTrack(_ kind: AudioTrack) throws {
        try workQueue.sync {
            drain()
            guard let index = tracks.firstIndex(where: { $0.kind == kind }) else { return }
            let track = tracks.remove(at: index)
            try track.writer.finish()
        }
    }

    func addTrack(_ kind: AudioTrack, ring: RealtimeBufferQueue) throws {
        try workQueue.sync {
            guard !tracks.contains(where: { $0.kind == kind }),
                  let scratch = AVAudioPCMBuffer(pcmFormat: ring.format, frameCapacity: ring.capacity) else {
                throw CaptureError.invalidConfiguration
            }
            let writer = try AudioChunkWriter(track: kind, inputFormat: ring.format,
                                              configuration: configuration, onEvent: onEvent)
            tracks.append(Track(kind: kind, ring: ring, scratch: scratch,
                                writer: writer, epochID: UUID().uuidString,
                                activatedAt: AVAudioTime.seconds(forHostTime: mach_absolute_time())))
            failed = false
        }
    }
    func finish() async {
        await withCheckedContinuation { continuation in
            workQueue.async {
                self.timer?.cancel(); self.timer = nil
                self.drain()
                let end = self.timeline.time(hostSeconds: AVAudioTime.seconds(forHostTime: mach_absolute_time()))
                for index in self.tracks.indices {
                    if let gap = self.tracks[index].waitingGap {
                        self.onEvent(.gap(CaptureGap(id: gap.id, meetingID: self.configuration.meetingID, startTime: gap.startTime, endTime: max(gap.startTime, end), reason: gap.reason + " Recording ended before the selected application supplied audio; no remote silence was fabricated.")))
                        self.tracks[index].waitingGap = nil
                    }
                }
                for track in self.tracks {
                    do { try track.writer.finish() } catch { self.onEvent(.interrupted("Could not finalize raw audio: \(error.localizedDescription)")) }
                }
                continuation.resume()
            }
        }
    }
}
