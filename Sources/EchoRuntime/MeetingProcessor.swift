import Foundation
import AVFoundation
import CryptoKit
import EchoCore
import EchoIntelligence

public enum MeetingProcessingError: LocalizedError {
    case missingModel(String), stagesFailed([String]), invalidResponse, meetingUnavailable, partialNotes
    public var errorDescription: String? {
        switch self {
        case .missingModel(let name): return "Install the local \(name) model in Settings, then retry processing."
        case .stagesFailed(let stages): return "Saved audio and available transcript are safe. Processing needs attention: " + stages.joined(separator: "; ")
        case .invalidResponse: return "The local worker returned inconsistent audio or timestamps."
        case .meetingUnavailable: return "The meeting could not be found."
        case .partialNotes: return "Some notes sections could not be generated. The partial draft is saved; Generate / Retry will create a new version."
        }
    }
}

struct ProcessingWindow: Codable, Sendable, Equatable {
    var track: AudioTrack
    var epochID: String
    var start: Double
    var duration: Double
    var windowID: String
    var provisional: Bool
    var relativePath: String
    var speakerModel: ModelSelection?
    var sequence: Int?
    var final: Bool?
    var epochStart: Double?
    var aecStateID: String?
    var windowSeconds: Int?
    var screenshotID: String?
    var ownershipStart: Double?
    var ownershipEnd: Double?
    var configuration: ProcessingConfiguration?
    var transcriptVersionID: String?
}

enum ProcessingIdentity {
    static func id(_ values: String...) -> String { id(values) }
    static func id(_ values: [String]) -> String { SHA256.hash(data: Data(values.joined(separator: "\u{1f}").utf8)).map { String(format: "%02x", $0) }.joined() }
    static func recordingFingerprint(_ chunks: [CapturedChunk]) -> String {
        let ordered = chunks.sorted { $0.startTime == $1.startTime ? $0.id < $1.id : $0.startTime < $1.startTime }
        return id(ordered.map { chunk in
            [chunk.id, chunk.epochID, chunk.track.rawValue, chunk.sha256.lowercased(), String(chunk.startTime.bitPattern), String(chunk.duration.bitPattern), String(chunk.sampleRate.bitPattern), String(chunk.frameCount)].joined(separator: ":")
        })
    }
    static func diarizationWindow(meetingID: String, chunks: [CapturedChunk], windowSeconds: Int?, track: AudioTrack = .remote, versionID: String? = nil) -> ProcessingWindow {
        let identity = id(meetingID, "diarize-track-v1", track.rawValue, versionID ?? "legacy", recordingFingerprint(chunks), String(windowSeconds ?? 0))
        return ProcessingWindow(track: track, epochID: "all", start: 0, duration: 0, windowID: identity, provisional: false, relativePath: "derived/grouping-\(track.rawValue)-\(identity).wav", windowSeconds: windowSeconds, transcriptVersionID: versionID)
    }
    static func speechWindows(meetingID: String, chunks: [CapturedChunk], final: Bool,
                              model: SpeechRecognitionModel = .whisper,
                              minimumOwnershipStart: Double? = nil,
                              maximumOwnershipStart: Double? = nil) -> [ProcessingWindow] {
        let groups = Dictionary(grouping: chunks) { $0.track.rawValue + ":" + $0.epochID }
        var result: [ProcessingWindow] = []
        for items in groups.values {
            let ordered = items.sorted { $0.startTime < $1.startTime }
            var runs: [[CapturedChunk]] = []
            for chunk in ordered {
                if let previous = runs.last?.last,
                   chunk.startTime > previous.startTime + previous.duration + 0.06 {
                    runs.append([chunk])
                } else if runs.isEmpty { runs.append([chunk]) }
                else { runs[runs.count - 1].append(chunk) }
            }
            for (runIndex, run) in runs.enumerated() {
                guard let first = run.first, let last = run.last else { continue }
                let end = run.map { $0.startTime + $0.duration }.max() ?? first.startTime
                let stableEnd = final ? end : last.startTime
                if let maximumOwnershipStart, maximumOwnershipStart < first.startTime { continue }
                var index = 0
                if let minimumOwnershipStart {
                    index = max(index, max(0, Int(floor((minimumOwnershipStart - first.startTime) / 28))))
                }
                while first.startTime + Double(index) * 28 < end - 0.001 {
                    let ownershipStart = first.startTime + Double(index) * 28
                    if let maximumOwnershipStart, ownershipStart > maximumOwnershipStart + 0.00001 { break }
                    let ownershipEnd = min(end, ownershipStart + 28)
                    let start = max(first.startTime, ownershipStart - 1)
                    let inputEnd = min(end, ownershipStart + 29)
                    let duration = inputEnd - start
                    let baseID = runIndex == 0
                        ? id(meetingID, first.epochID, first.track.rawValue, "overlap-v1", String(index))
                        : id(meetingID, first.epochID, first.track.rawValue, "overlap-v1-gap", String(first.startTime.bitPattern), String(index))
                    let windowID = model == .whisper ? baseID : id(baseID, model.rawValue)
                    let provisional = !final && inputEnd > stableEnd + 0.0001
                    let version = id(windowID, String(Int((duration * 16000).rounded())), provisional ? "preview" : "final")
                    result.append(ProcessingWindow(track: first.track, epochID: first.epochID, start: start, duration: duration, windowID: windowID, provisional: provisional, relativePath: "derived/asr-\(version).wav", ownershipStart: ownershipStart, ownershipEnd: ownershipEnd))
                    index += 1
                }
            }
        }
        return result.sorted { $0.start == $1.start ? $0.track.rawValue < $1.track.rawValue : $0.start < $1.start }
    }
    static func jobID(_ window: ProcessingWindow, kind: JobKind) -> String {
        id(kind.rawValue, window.windowID, String(Int((window.duration * 16000).rounded())), window.provisional ? "preview" : "final", String(window.sequence ?? -1), String(window.final ?? false), String(window.windowSeconds ?? 0))
    }
}

/// Audio revisions change ASR job identities. Keep the timeline coverage of
/// completed predecessor windows so finalization only schedules missing speech.
enum RetainedSpeechCoverage {
    static func extending(_ completed: [CompletedSpeechWindow], with segments: [TranscriptSegment],
                          excluding deleted: Range<Double>) -> [CompletedSpeechWindow] {
        completed.map { window in
            let retained = segments.filter { segment in
                segment.windowID == window.windowID && segment.track == window.track &&
                !segment.isProvisional &&
                !(segment.startTime < deleted.upperBound && segment.endTime > deleted.lowerBound)
            }
            return CompletedSpeechWindow(windowID: window.windowID, track: window.track,
                epochID: window.epochID,
                ownershipStart: min(window.ownershipStart, retained.map(\.startTime).min() ?? window.ownershipStart),
                ownershipEnd: max(window.ownershipEnd, retained.map(\.endTime).max() ?? window.ownershipEnd))
        }
    }

    static func uncoveredChunks(_ chunks: [CapturedChunk], completed: [CompletedSpeechWindow]) -> [CapturedChunk] {
        guard !completed.isEmpty else { return chunks }
        var result: [CapturedChunk] = []
        for chunk in chunks {
            let chunkEnd = chunk.startTime + chunk.duration
            var cursor = chunk.startTime
            let intervals = completed.filter { $0.track == chunk.track &&
                $0.ownershipStart < chunkEnd && $0.ownershipEnd > chunk.startTime }
                .sorted { $0.ownershipStart < $1.ownershipStart }
            func append(_ start: Double, _ end: Double) {
                guard end > start + 0.00001 else { return }
                var slice = chunk
                slice.startTime = start
                slice.duration = end - start
                slice.frameCount = Int64((slice.duration * slice.sampleRate).rounded())
                result.append(slice)
            }
            for interval in intervals {
                append(cursor, min(chunkEnd, interval.ownershipStart))
                cursor = max(cursor, min(chunkEnd, interval.ownershipEnd))
            }
            append(cursor, chunkEnd)
        }
        return result
    }
}

/// AEC adaptation belongs to microphone epochs; far audio is selected by
/// meeting-time coverage and may span unrelated application capture epochs.
enum AECWindowPlanner {
    static func windows(meetingID: String, raw: [CapturedChunk], final: Bool,
                        stateNamespace: String? = nil) -> [ProcessingWindow] {
        let microphones = raw.filter { $0.track == .microphone }
        let remoteCoverage = coverage(raw.filter { $0.track == .remote })
        var planned: [ProcessingWindow] = []
        for (epoch, items) in Dictionary(grouping: microphones, by: \.epochID) {
            let near = items.sorted { $0.startTime < $1.startTime }
            guard let first = near.first, let last = near.last else { continue }
            let epochClosed = final || microphones.contains { $0.epochID != epoch && $0.startTime > last.startTime }
            let stableEnd = epochClosed ? last.startTime + last.duration : last.startTime
            var covered: [(start: Double, end: Double)] = []
            for nearInterval in coverage(near) {
                for farInterval in remoteCoverage {
                    let start = max(nearInterval.start, farInterval.start)
                    let end = min(nearInterval.end, farInterval.end)
                    if end > start + 0.00001 { covered.append((start, end)) }
                }
            }
            covered.sort { $0.start < $1.start }
            for (runIndex, interval) in covered.enumerated() {
                let closed = epochClosed || runIndex + 1 < covered.count
                let end = min(interval.end, stableEnd)
                guard end > interval.start + 0.00001 else { continue }
                let stateID: String
                if let stateNamespace {
                    stateID = ProcessingIdentity.id(meetingID, epoch, "aec-repair", stateNamespace,
                                                    String(interval.start.bitPattern))
                } else {
                    stateID = runIndex == 0 && abs(interval.start - first.startTime) < 0.00001
                        ? epoch : ProcessingIdentity.id(meetingID, epoch, "aec-run", String(interval.start.bitPattern))
                }
                var sequence = 0
                var processedEnd = interval.start
                while interval.start + Double(sequence) * 5 < end - 0.00001 {
                    let start = interval.start + Double(sequence) * 5
                    let duration = min(5, end - start)
                    if duration < 4.99999 && !closed { break }
                    let windowID = ProcessingIdentity.id(meetingID, stateID, "aec", String(sequence))
                    planned.append(ProcessingWindow(track: .cleanMicrophone, epochID: epoch, start: start,
                                                    duration: duration, windowID: windowID, provisional: false,
                                                    relativePath: "derived/clean-\(windowID).wav", sequence: sequence,
                                                    final: false, epochStart: interval.start, aecStateID: stateID))
                    processedEnd = start + duration
                    sequence += 1
                }
                if closed && sequence > 0 {
                    let windowID = ProcessingIdentity.id(meetingID, stateID, "aec-flush", String(sequence))
                    planned.append(ProcessingWindow(track: .cleanMicrophone, epochID: epoch,
                                                    start: processedEnd, duration: 0, windowID: windowID,
                                                    provisional: false, relativePath: "derived/clean-\(windowID).wav",
                                                    sequence: sequence, final: true, epochStart: interval.start,
                                                    aecStateID: stateID))
                }
            }
        }
        return planned.sorted { $0.start == $1.start ? $0.epochID < $1.epochID : $0.start < $1.start }
    }

    private static func coverage(_ chunks: [CapturedChunk]) -> [(start: Double, end: Double)] {
        var merged: [(start: Double, end: Double)] = []
        for chunk in chunks.sorted(by: { $0.startTime < $1.startTime }) {
            let end = chunk.startTime + chunk.duration
            if let last = merged.indices.last, chunk.startTime <= merged[last].end + 1.0 / 16_000 {
                merged[last].end = max(merged[last].end, end)
            } else {
                merged.append((chunk.startTime, end))
            }
        }
        return merged
    }
}

enum AECRepairPlanner {
    /// Existing clean output is authoritative. Reprepare only raw intervals
    /// missing clean coverage, using fresh AEC state after a deletion.
    static func missingNearChunks(near: [CapturedChunk], clean: [CapturedChunk]) -> [CapturedChunk] {
        let gaps = AECCoverageAudit.uncovered(near: near, clean: clean)
        return near.flatMap { chunk -> [CapturedChunk] in
            gaps.compactMap { gap in
                guard gap.epochID == chunk.epochID else { return nil }
                let start = max(chunk.startTime, gap.start)
                let end = min(chunk.startTime + chunk.duration, gap.end)
                guard end > start + 0.00001 else { return nil }
                var slice = chunk
                slice.startTime = start
                slice.duration = end - start
                slice.frameCount = Int64((slice.duration * slice.sampleRate).rounded())
                return slice
            }
        }
    }
}

/// Coverage is evaluated per epoch; one successful epoch must never conceal
/// microphone speech lost from a later epoch's derived transcript input.
public enum AECCoverageAudit {
    public struct Interval: Equatable { var epochID: String; var start: Double; var end: Double }
    public static func uncovered(near: [CapturedChunk], clean: [CapturedChunk]) -> [Interval] {
        var result: [Interval] = []
        for (epoch, chunks) in Dictionary(grouping: near, by: \.epochID) {
            let reference = clean.filter { $0.epochID == epoch }.sorted { $0.startTime < $1.startTime }
            var missing: [Interval] = []
            for chunk in chunks.sorted(by: { $0.startTime < $1.startTime }) {
                var cursor = chunk.startTime
                let end = chunk.startTime + chunk.duration
                for covered in reference where covered.startTime + covered.duration > cursor && covered.startTime < end {
                    if covered.startTime > cursor { missing.append(Interval(epochID: epoch, start: cursor, end: min(end, covered.startTime))) }
                    cursor = max(cursor, min(end, covered.startTime + covered.duration))
                }
                if cursor < end { missing.append(Interval(epochID: epoch, start: cursor, end: end)) }
            }
            var merged: [Interval] = []
            for interval in missing.sorted(by: { $0.start < $1.start }) {
                if let last = merged.last, interval.start <= last.end + 1.0 / 16000 {
                    merged[merged.count - 1].end = max(last.end, interval.end)
                } else { merged.append(interval) }
            }
            // One AEC 10 ms frame is the maximum endpoint/alignment tolerance.
            result += merged.filter { $0.end - $0.start > 0.010001 }
        }
        return result.sorted { $0.start == $1.start ? $0.epochID < $1.epochID : $0.start < $1.start }
    }
}

struct TranscriptionSnapshot: Codable, Sendable {
    var window: ProcessingWindow
    var segments: [TranscriptSegment]
}

/// Whisper returns independently chosen segment boundaries, not word timestamps.
/// Preserve original window results and reconcile their shared lexical suffix/prefix;
/// never assume identical intervals, and never overwrite a human correction.
enum LexicalBoundaryReconciler {
    private static let tokenPattern = try! NSRegularExpression(pattern: #"[\p{L}\p{N}]+(?:['’][\p{L}\p{N}]+)*"#)
    private static func tokens(_ text: String) -> [(word: String, range: NSRange)] {
        let string = text as NSString
        return tokenPattern.matches(in: text, range: NSRange(location: 0, length: string.length)).map {
            (string.substring(with: $0.range).lowercased(), $0.range)
        }
    }
    static func reconcile(_ snapshots: [TranscriptionSnapshot], existing: [TranscriptSegment]) -> [TranscriptionSnapshot] {
        let ordered = snapshots.sorted { ($0.window.ownershipStart ?? $0.window.start) < ($1.window.ownershipStart ?? $1.window.start) }
        var output: [TranscriptionSnapshot] = []
        for snapshot in ordered {
            let ownerStart = snapshot.window.ownershipStart ?? snapshot.window.start
            let ownerEnd = snapshot.window.ownershipEnd ?? (snapshot.window.start + snapshot.window.duration)
            var current = snapshot.segments.filter { $0.endTime > ownerStart && $0.startTime < ownerEnd }.sorted { $0.startTime < $1.startTime }
            if let previous = output.last, previous.window.epochID == snapshot.window.epochID, previous.window.track == snapshot.window.track {
                let overlapStart = snapshot.window.start
                let overlapEnd = min(previous.window.start + previous.window.duration, snapshot.window.start + snapshot.window.duration)
                if overlapEnd > overlapStart {
                    let prior = previous.segments.filter { $0.endTime > overlapStart - 0.25 }
                    let currentIndices = current.indices.filter { current[$0].startTime < overlapEnd + 0.25 }
                    // Equal words spoken later are a real repetition. Decoder
                    // duplication needs overlapping audio time as well as text.
                    let sharesAudioTime = prior.last.map { previousEnd in
                        currentIndices.first.map { current[$0].startTime + 0.05 < previousEnd.endTime } ?? false
                    } ?? false
                    let left: [String] = sharesAudioTime ? Array(prior.flatMap { tokens($0.text).map(\.word) }.suffix(100)) : []
                    let right: [String] = sharesAudioTime ? Array(currentIndices.flatMap { tokens(current[$0].text).map(\.word) }.prefix(100)) : []
                    var duplicateWords = 0
                    let maximum = min(left.count, right.count)
                    if maximum > 0 {
                        for length in stride(from: maximum, through: 1, by: -1) {
                            if Array(left.suffix(length)) == Array(right.prefix(length)), length >= 2 || (left.count == 1 && right.count == 1) || (length == 1 && (left.last?.count ?? 0) >= 4) {
                                duplicateWords = length; break
                            }
                        }
                    }
                    var removeIDs = Set<String>()
                    for index in currentIndices where duplicateWords > 0 {
                        let words = tokens(current[index].text)
                        let removed = min(duplicateWords, words.count)
                        duplicateWords -= removed
                        if removed == words.count, removed > 0 { removeIDs.insert(current[index].id) }
                        else if removed > 0 {
                            if current[index].recognitionEvidence?.sourceStart == nil {
                                let start = current[index].startTime, end = current[index].endTime
                                current[index].recognitionEvidence?.sourceStart = start
                                current[index].recognitionEvidence?.sourceEnd = end
                            }
                            let source = current[index].text as NSString
                            let cut = words[removed].range.location
                            current[index].text = source.substring(from: cut)
                            current[index].words = current[index].words?.compactMap { word in
                                guard word.location >= cut else { return nil }; var copy = word; copy.location -= cut; return copy
                            }
                            let span = current[index].endTime - current[index].startTime
                            current[index].startTime += span * Double(removed) / Double(words.count)
                            current[index].isUncertain = true // interpolated segment timing, never fabricated word timestamps
                        }
                    }
                    current.removeAll { removeIDs.contains($0.id) }
                }
            }
            output.append(TranscriptionSnapshot(window: snapshot.window, segments: current))
        }
        // Use machine text for overlap matching, then restore edits verbatim. Even
        // an edited row whose complete machine result was duplicate is retained.
        for index in output.indices {
            let edited = existing.filter { $0.windowID == output[index].window.windowID && $0.isEdited }
            for correction in edited {
                if let position = output[index].segments.firstIndex(where: { $0.id == correction.id }) {
                    output[index].segments[position].text = correction.text
                    output[index].segments[position].isEdited = true
                    output[index].segments[position].words = correction.words
                } else {
                    var retained = correction
                    if !output[index].window.provisional { retained.isProvisional = false }
                    output[index].segments.append(retained)
                }
            }
            output[index].segments.sort { $0.startTime == $1.startTime ? $0.id < $1.id : $0.startTime < $1.startTime }
        }
        return output
    }
}

/// Owns inference scheduling only. Recording and its durable files never depend
/// on this actor, the Python process, model readiness, or successful inference.
public actor MeetingProcessor {
    private let store: MeetingStore
    private let paths: AppPaths
    private let service: any MeetingAudioService
    private let intelligence: LocalIntelligence
    private let assembler: AudioWindowAssembler
    private var liveTask: Task<Void, Never>?
    private var liveRecognitionTask: Task<Void, Error>?
    private var finalTask: Task<Void, Error>?
    private var activeJobID: String?
    private var activeJobKind: JobKind?
    private var liveGeneration = 0
    private var lastTrack: AudioTrack?
    private var lastMessage = ""
    private var knownJobIDs: [String: Set<String>] = [:]
    private struct ChunkSnapshot {
        var audioRevision = 0
        var lastRowID: Int64 = 0
        var generation = 0
        var rawGeneration = 0
        var chunks: [CapturedChunk] = []
    }
    private var chunkSnapshots: [String: ChunkSnapshot] = [:]
    private var preparationPlanKeys: [String: String] = [:]
    private var speechPlanKeys: [String: String] = [:]
    private var speechPlanIDs: [String: Set<String>] = [:]
    private var speechPlanWindows: [String: [ProcessingWindow]] = [:]
    private var speechPlanChunkCounts: [String: Int] = [:]
    private let maximumAttempts = 3
    private var previewTimes: [AudioTrack: Date] = [:]

    public init(store: MeetingStore, paths: AppPaths, service: any MeetingAudioService, intelligence: LocalIntelligence) {
        self.store = store; self.paths = paths; self.service = service; self.intelligence = intelligence
        assembler = AudioWindowAssembler(paths: paths, audioAssets: store.audioAssets)
    }
    public func startLive(meetingID: String, onUpdate: @escaping @Sendable (String) -> Void) async {
        await cancel()
        do { _ = try store.liveTranscriptionPolicy(meetingID: meetingID) }
        catch { onUpdate(error.localizedDescription); return }
        do { try store.recoverRunningJobs() } catch { onUpdate(error.localizedDescription); return }
        lastMessage = ""
        liveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do { _ = try await self.processAudio(meetingID: meetingID, final: false, onUpdate: onUpdate) }
                catch is CancellationError { if Task.isCancelled { return } }
                catch { await self.report(error.localizedDescription, to: onUpdate) }
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            }
        }
    }
    public func stopLiveTranscription(meetingID: String, effectiveTime: Double) async throws {
        _ = try store.stopLiveTranscription(meetingID: meetingID, effectiveTime: effectiveTime)
        liveGeneration += 1
        liveRecognitionTask?.cancel()
        if activeJobKind == .transcribe {
            if let activeJobID { await service.cancel(jobID: activeJobID) }
        }
        // A running AEC preparation may finish; the persisted policy closes ASR
        // admission before the next scheduler step.
    }
    public func stopLive() async {
        liveRecognitionTask?.cancel()
        let task = liveTask; liveTask = nil; task?.cancel()
        if let activeJobID { await service.cancel(jobID: activeJobID) }
        await task?.value
    }
    public func cancel() async {
        let final = finalTask; finalTask = nil; final?.cancel()
        await stopLive()
        if let activeJobID { await service.cancel(jobID: activeJobID) }
        _ = try? await final?.value
        await service.unload(); await intelligence.releaseCache(); knownJobIDs.removeAll()
    }
    public func finalize(meetingID: String, onUpdate: @escaping @Sendable (String) -> Void) async throws {
        try await finalize(meetingID: meetingID, diarizationWindowSeconds: nil, onUpdate: onUpdate)
    }
    public func groupSpeakers(meetingID: String, versionID: String, model: ModelSelection) async throws {
        await cancel()
        guard let meeting = try store.meeting(id: meetingID),
              ![.recording, .paused, .interrupted].contains(meeting.state),
              try store.activeTranscriptVersion(meetingID: meetingID) == versionID else {
            throw MeetingProcessingError.meetingUnavailable
        }
        let source = try store.chunks(meetingID: meetingID, track: meeting.recordingMode.groupingTrack)
        guard !source.isEmpty else { throw MeetingProcessingError.meetingUnavailable }
        var payload = ProcessingIdentity.diarizationWindow(meetingID: meetingID, chunks: source,
                                                              windowSeconds: nil, track: meeting.recordingMode.groupingTrack,
                                                              versionID: versionID)
        payload.speakerModel = model
        payload.windowID = ProcessingIdentity.id(payload.windowID, model.id, model.revision)
        try enqueue(payload, kind: .diarize, meetingID: meetingID)
        let jobID = ProcessingIdentity.jobID(payload, kind: .diarize)
        guard let job = try store.jobs(meetingID: meetingID).first(where: { $0.id == jobID }) else {
            throw MeetingProcessingError.invalidResponse
        }
        if job.status != .completed {
            try await execute(job, onUpdate: { _ in }) { payload in
                try await self.diarize(job: job, payload: payload, remote: source)
            }
        }
        guard try store.jobs(meetingID: meetingID).first(where: { $0.id == jobID })?.status == .completed else {
            throw MeetingProcessingError.stagesFailed(["Speaker grouping could not finish. Retry from Review speakers."])
        }
    }
    public func finalize(meetingID: String, diarizationWindowSeconds: Int?, onUpdate: @escaping @Sendable (String) -> Void) async throws {
        guard diarizationWindowSeconds == nil || diarizationWindowSeconds == 1800 else { throw MeetingProcessingError.invalidResponse }
        await cancel()
        try store.recoverRunningJobs()
        let task = Task { try await self.runFinalization(meetingID: meetingID, diarizationWindowSeconds: diarizationWindowSeconds, onUpdate: onUpdate) }
        finalTask = task
        do { try await task.value; finalTask = nil }
        catch { finalTask = nil; throw error }
    }
    public func regenerate(meetingID: String, configuration: ProcessingConfiguration, onUpdate: @escaping @Sendable (String) -> Void) async throws -> String {
        await cancel()
        guard let meeting = try store.meeting(id: meetingID), ![.recording, .paused, .interrupted].contains(meeting.state) else { throw MeetingProcessingError.meetingUnavailable }
        let chunks = try store.chunks(meetingID: meetingID)
        if try !store.speakerphoneMicrophoneChunks(meetingID: meetingID).isEmpty { try auditPreparedCoverage(meetingID: meetingID) }
        let selected = chunks.filter { $0.track == .remote } + (try store.microphoneTranscriptChunks(meetingID: meetingID))
        var version = TranscriptVersion(meetingID: meetingID, configuration: configuration, audioFingerprint: ProcessingIdentity.recordingFingerprint(chunks))
        try store.saveTranscriptVersion(version)
        let versionID = version.id
        let task = Task {
            let model: SpeechRecognitionModel = configuration.speech.id == "parakeet" ? .parakeet : .whisper
            let windows = try self.configuredWindows(meetingID: meetingID, chunks: selected, final: true, model: model, configuration: configuration, versionID: versionID)
            guard !windows.isEmpty else { throw MeetingProcessingError.meetingUnavailable }
            for window in windows {
                try Task.checkCancellation()
                try self.enqueue(window, kind: .transcribe, meetingID: meetingID)
                guard let job = try self.store.jobs(meetingID: meetingID).first(where: { $0.id == ProcessingIdentity.jobID(window, kind: .transcribe) }) else { throw MeetingProcessingError.invalidResponse }
                if job.status != .completed {
                    try await self.execute(job, onUpdate: onUpdate) { payload in try await self.transcribe(job: job, payload: payload, language: meeting.language, model: model) }
                    guard try self.store.jobs(meetingID: meetingID).first(where: { $0.id == job.id })?.status == .completed else { throw MeetingProcessingError.stagesFailed(["Transcript regeneration could not finish. The previous transcript is unchanged."]) }
                }
            }
        }
        finalTask = task
        do {
            try await task.value; try Task.checkCancellation()
            version.status = .ready; try store.saveTranscriptVersion(version)
            finalTask = nil; await service.unload(); return versionID
        } catch {
            version.status = task.isCancelled || Task.isCancelled ? .cancelled : .failed
            try? store.saveTranscriptVersion(version); finalTask = nil; await service.unload(); throw error
        }
    }

    private func report(_ message: String, to update: @Sendable (String) -> Void) {
        guard message != lastMessage else { return }; lastMessage = message; update(message)
    }
    private func enqueue(_ payload: ProcessingWindow, kind: JobKind, meetingID: String) throws {
        if knownJobIDs[meetingID] == nil { knownJobIDs[meetingID] = try store.processingJobIDs(meetingID: meetingID) }
        let id = ProcessingIdentity.jobID(payload, kind: kind)
        guard !(knownJobIDs[meetingID]?.contains(id) ?? false) else { return }
        let data = try JSONEncoder().encode(payload)
        try store.enqueue(ProcessingJob(id: id, meetingID: meetingID, kind: kind, status: .pending, payload: String(decoding: data, as: UTF8.self), attempts: 0, error: nil, createdAt: Date()))
        knownJobIDs[meetingID, default: []].insert(id)
    }
    private func decode(_ job: ProcessingJob) throws -> ProcessingWindow { try JSONDecoder().decode(ProcessingWindow.self, from: Data(job.payload.utf8)) }
    private func canRun(_ job: ProcessingJob) -> Bool { (job.status == .pending || job.status == .failed) && job.attempts < maximumAttempts }

    private func chunkSnapshot(meetingID: String) throws -> ChunkSnapshot {
        let revision = try store.audioRevision(meetingID: meetingID)
        var snapshot = chunkSnapshots[meetingID] ?? ChunkSnapshot()
        if snapshot.audioRevision != revision {
            snapshot = ChunkSnapshot(audioRevision: revision)
            preparationPlanKeys.removeValue(forKey: meetingID)
            speechPlanKeys.removeValue(forKey: meetingID)
            speechPlanIDs.removeValue(forKey: meetingID)
            speechPlanWindows.removeValue(forKey: meetingID)
            speechPlanChunkCounts.removeValue(forKey: meetingID)
            knownJobIDs.removeValue(forKey: meetingID)
        }
        while true {
            let added = try store.chunksAdded(meetingID: meetingID, afterRowID: snapshot.lastRowID)
            guard !added.isEmpty else { break }
            snapshot.lastRowID = added.last!.rowID
            snapshot.chunks.append(contentsOf: added.map(\.chunk))
            snapshot.generation += added.count
            snapshot.rawGeneration += added.filter { $0.chunk.track != .cleanMicrophone }.count
            if added.count < 512 { break }
        }
        chunkSnapshots[meetingID] = snapshot
        return snapshot
    }

    /// One AEC job and one ASR job per iteration: both tracks get a turn even
    /// when new microphone audio keeps arriving faster than recognition.
    private func processAudio(meetingID: String, final: Bool, prepareOnly: Bool = false,
                              onUpdate: @escaping @Sendable (String) -> Void) async throws -> Bool {
        try Task.checkCancellation()
        guard let meeting = try store.meeting(id: meetingID) else { throw MeetingProcessingError.meetingUnavailable }
        var progress = false
        var snapshot = try chunkSnapshot(meetingID: meetingID)
        let raw = snapshot.chunks.filter { $0.track != .cleanMicrophone }
        let modes = Dictionary(uniqueKeysWithValues: try store.microphoneProcessingEpochs(meetingID: meetingID)
            .map { ($0.epochID, $0.acousticMode) })
        let legacyMode: CaptureAcousticMode = meeting.usesEchoCancellation ? .speakerphone : .headphones
        let speakerphone = raw.filter { $0.track == .microphone &&
            (modes[$0.epochID] ?? legacyMode) == .speakerphone }
        if !speakerphone.isEmpty {
            let key = "\(snapshot.audioRevision):\(snapshot.rawGeneration):\(final)"
            if preparationPlanKeys[meetingID] != key {
                let repair = snapshot.audioRevision > 0
                let unfinishedPreparation = repair ? try store.unfinishedJobs(meetingID: meetingID, kind: .prepareAudio) : []
                let pendingRepair = unfinishedPreparation.contains { (try? decode($0).sequence) != nil }
                if !pendingRepair {
                    let near = repair
                        ? AECRepairPlanner.missingNearChunks(near: speakerphone,
                                                             clean: snapshot.chunks.filter { $0.track == .cleanMicrophone })
                        : speakerphone
                    if !near.isEmpty {
                        try planPreparation(meetingID: meetingID,
                                            raw: near + raw.filter { $0.track == .remote }, final: final,
                                            stateNamespace: repair ? "redaction-\(snapshot.audioRevision)" : nil)
                    }
                    preparationPlanKeys[meetingID] = key
                }
            }
        }
        // A terminal AEC flush may be pending even when the cleaned chunks
        // already satisfy coverage tolerance. Coverage cannot stand in for a
        // completed worker receipt.
        if let job = try nextPreparation(meetingID: meetingID) {
            progress = true
            try await execute(job, onUpdate: onUpdate) { payload in try await self.prepare(job: job, payload: payload) }
            if final { return true }
        }
        if prepareOnly { return progress }
        try Task.checkCancellation()
        if !final, try !store.liveTranscriptionPolicy(meetingID: meetingID).admitsLiveRecognition { return progress }
        snapshot = try chunkSnapshot(meetingID: meetingID)
        let selected = snapshot.chunks.filter { $0.track == .remote ||
            ($0.track == .microphone && (modes[$0.epochID] ?? legacyMode) == .headphones) ||
            ($0.track == .cleanMicrophone && (modes[$0.epochID] ?? legacyMode) == .speakerphone) }
        let speechKey = "\(snapshot.audioRevision):\(snapshot.generation):\(final)"
        if speechPlanKeys[meetingID] != speechKey {
            let configuration = try store.configuration(meetingID: meetingID)
            let completed = final && snapshot.audioRevision > 0
                ? try store.redactions(meetingID: meetingID).flatMap(\.completedSpeechWindows) : []
            let planningChunks = RetainedSpeechCoverage.uncoveredChunks(selected, completed: completed)
            var windows: [ProcessingWindow]
            let closingLivePlan = final && speechPlanKeys[meetingID]?.hasSuffix(":false") == true
            if let previous = speechPlanWindows[meetingID], !closingLivePlan {
                windows = previous
                let previousCount = min(speechPlanChunkCounts[meetingID] ?? 0, snapshot.chunks.count)
                let addedIDs = Set(snapshot.chunks.dropFirst(previousCount).map(\.id))
                var changedStarts: [AudioTrack: Double] = [:]
                for chunk in planningChunks where addedIDs.contains(chunk.id) {
                    let lower = max(0, chunk.startTime - 30)
                    changedStarts[chunk.track] = min(changedStarts[chunk.track] ?? lower, lower)
                }
                for window in previous where window.provisional && (final || changedStarts[window.track] != nil) {
                    let lower = window.ownershipStart ?? window.start
                    changedStarts[window.track] = min(changedStarts[window.track] ?? lower, lower)
                }
                for (track, lower) in changedStarts {
                    let refreshed = try configuredWindows(meetingID: meetingID,
                        chunks: planningChunks.filter { $0.track == track }, final: final,
                        model: meeting.recognitionModel, configuration: configuration,
                        minimumOwnershipStart: lower)
                    let replaceFrom = refreshed.map { $0.ownershipStart ?? $0.start }.min() ?? lower
                    windows.removeAll { $0.track == track && ($0.ownershipStart ?? $0.start) >= replaceFrom }
                    windows.append(contentsOf: refreshed)
                    for window in refreshed { try enqueue(window, kind: .transcribe, meetingID: meetingID) }
                }
            } else {
                windows = try configuredWindows(meetingID: meetingID, chunks: planningChunks, final: final,
                                                model: meeting.recognitionModel, configuration: configuration)
                for window in windows { try enqueue(window, kind: .transcribe, meetingID: meetingID) }
            }
            let latestPreviews = Dictionary(grouping: windows.filter(\.provisional), by: \.track)
                .mapValues { $0.map { $0.ownershipStart ?? $0.start }.max() ?? 0 }
            windows.removeAll { $0.provisional && ($0.ownershipStart ?? $0.start) < (latestPreviews[$0.track] ?? 0) }
            speechPlanWindows[meetingID] = windows
            speechPlanChunkCounts[meetingID] = snapshot.chunks.count
            speechPlanIDs[meetingID] = Set(windows.map { ProcessingIdentity.jobID($0, kind: .transcribe) })
            speechPlanKeys[meetingID] = speechKey
        }
        let currentIDs = speechPlanIDs[meetingID] ?? []
        var jobs = try store.unfinishedJobs(meetingID: meetingID, kind: .transcribe)
        for index in jobs.indices where !currentIDs.contains(jobs[index].id) {
            jobs[index].status = .cancelled; jobs[index].error = "Superseded by a newer snapshot of the same audio window"; try store.updateJob(jobs[index])
            if let obsolete = try? decode(jobs[index]), let url = try? paths.resolveMeetingAsset(meetingID: meetingID, relativePath: obsolete.relativePath) { try? FileManager.default.removeItem(at: url) }
        }
        let decoded = try jobs.filter { canRun($0) && currentIDs.contains($0.id) }.map { ($0, try decode($0)) }
        let finalBacklog = decoded.filter { !$0.1.provisional }.count
        let candidates = decoded.filter { _, window in
            !window.provisional || (finalBacklog == 0 && Date().timeIntervalSince(previewTimes[window.track] ?? .distantPast) >= 10)
        }.sorted {
            if $0.1.provisional != $1.1.provisional { return !$0.1.provisional }
            if ($0.1.track == lastTrack) != ($1.1.track == lastTrack) { return $0.1.track != lastTrack }
            if $0.1.start != $1.1.start { return $0.1.start < $1.1.start }
            return !$0.1.provisional && $1.1.provisional
        }
        if let (job, payload) = candidates.first {
            progress = true; lastTrack = payload.track
            if payload.provisional { previewTimes[payload.track] = Date() }
            if finalBacklog > 1 { report("Catching up — audio is saved (\(finalBacklog * 28) seconds queued)", to: onUpdate) }
            let generation = final ? nil : liveGeneration
            try await execute(job, onUpdate: onUpdate) { payload in
                if let generation {
                    let task = Task { try await self.transcribe(job: job, payload: payload, language: meeting.language, model: meeting.recognitionModel, liveGeneration: generation) }
                    self.liveRecognitionTask = task
                    defer { self.liveRecognitionTask = nil }
                    try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                } else {
                    try await self.transcribe(job: job, payload: payload, language: meeting.language, model: meeting.recognitionModel)
                }
            }
        }
        return progress
    }

    private func configuredWindows(meetingID: String, chunks: [CapturedChunk], final: Bool, model: SpeechRecognitionModel,
                                    configuration: ProcessingConfiguration?, versionID: String? = nil,
                                    minimumOwnershipStart: Double? = nil,
                                    maximumOwnershipStart: Double? = nil) throws -> [ProcessingWindow] {
        let audioRevision = try store.audioRevision(meetingID: meetingID)
        return ProcessingIdentity.speechWindows(meetingID: meetingID, chunks: chunks, final: final, model: model,
                                                minimumOwnershipStart: minimumOwnershipStart,
                                                maximumOwnershipStart: maximumOwnershipStart).map { source in
            var window = source
            if audioRevision > 0 {
                window.windowID = ProcessingIdentity.id(window.windowID, "audio-revision", String(audioRevision))
                window.relativePath = "derived/asr-" + window.windowID + ".wav"
            }
            if let configuration {
                window.windowID = ProcessingIdentity.id(window.windowID, configuration.id, versionID ?? "recording")
                window.relativePath = "derived/asr-" + ProcessingIdentity.id(window.windowID, String(window.duration), String(window.provisional)) + ".wav"
                window.configuration = configuration; window.transcriptVersionID = versionID
            }
            return window
        }
    }

    private func planPreparation(meetingID: String, raw: [CapturedChunk], final: Bool,
                                 stateNamespace: String? = nil) throws {
        for window in AECWindowPlanner.windows(meetingID: meetingID, raw: raw, final: final,
                                                stateNamespace: stateNamespace) {
            try enqueue(window, kind: .prepareAudio, meetingID: meetingID)
        }
    }
    private func nextPreparation(meetingID: String) throws -> ProcessingJob? {
        let jobs = try store.unfinishedJobs(meetingID: meetingID, kind: .prepareAudio)
        let decoded = try jobs.map { ($0, try decode($0)) }.sorted { $0.1.start == $1.1.start ? ($0.1.sequence ?? 0) < ($1.1.sequence ?? 0) : $0.1.start < $1.1.start }
        return decoded.first { candidate in
            guard canRun(candidate.0), candidate.1.sequence != nil else { return false }
            let stateID = candidate.1.aecStateID ?? candidate.1.epochID
            return !decoded.contains { ($0.1.aecStateID ?? $0.1.epochID) == stateID &&
                ($0.1.sequence ?? 0) < (candidate.1.sequence ?? 0) && $0.0.status != .completed }
        }?.0
    }
    private struct PreparedInputProof: Codable { let nearHash: String; let farHash: String }
    private func prepare(job: ProcessingJob, payload: ProcessingWindow) async throws {
        let health = try await service.health()
        guard health.capabilities.prepare_audio else { throw MeetingProcessingError.missingModel("echo cancellation runtime") }
        let nearPath = "derived/aec-near-\(payload.windowID).wav", farPath = "derived/aec-far-\(payload.windowID).wav"
        let nearChunks = payload.duration > 0
            ? try store.chunksOverlapping(meetingID: job.meetingID, track: .microphone,
                                          start: payload.start, end: payload.start + payload.duration) : []
        let farChunks = payload.duration > 0
            ? try store.chunksOverlapping(meetingID: job.meetingID, track: .remote,
                                          start: payload.start, end: payload.start + payload.duration) : []
        let nearURL = try paths.resolveMeetingAsset(meetingID: job.meetingID, relativePath: nearPath)
        let farURL = try paths.resolveMeetingAsset(meetingID: job.meetingID, relativePath: farPath)
        let proofURL = try paths.resolveMeetingAsset(meetingID: job.meetingID, relativePath: "derived/aec-input-\(payload.windowID).json")
        if FileManager.default.fileExists(atPath: proofURL.path) {
            let proof = try JSONDecoder().decode(PreparedInputProof.self, from: Data(contentsOf: proofURL))
            guard try AudioWindowAssembler.digest(nearURL) == proof.nearHash,
                  try AudioWindowAssembler.digest(farURL) == proof.farHash else { throw MeetingProcessingError.invalidResponse }
        } else {
            let outputURL = try paths.resolveMeetingAsset(meetingID: job.meetingID, relativePath: payload.relativePath)
            guard !FileManager.default.fileExists(atPath: outputURL.path) else { throw MeetingProcessingError.invalidResponse }
            if payload.duration == 0 {
                _ = try assembler.emptyWave(meetingID: job.meetingID, relativePath: nearPath)
                _ = try assembler.emptyWave(meetingID: job.meetingID, relativePath: farPath)
            } else {
                let near = try assembler.assemble(meetingID: job.meetingID, chunks: nearChunks.filter { $0.epochID == payload.epochID }, start: payload.start, duration: payload.duration, relativePath: nearPath)
                let far = try assembler.assemble(meetingID: job.meetingID, chunks: farChunks, start: payload.start, duration: payload.duration, relativePath: farPath)
                guard near.isFullyCovered, far.isFullyCovered, near.frameCount == far.frameCount else {
                    try? FileManager.default.removeItem(at: near.url); try? FileManager.default.removeItem(at: far.url)
                    throw AudioAssemblyError.missingReference
                }
            }
            // Commit proof before invoking Python. Once journaled, replay inputs
            // must never change, including when a native job is retried after crash.
            let proof = PreparedInputProof(nearHash: try AudioWindowAssembler.digest(nearURL), farHash: try AudioWindowAssembler.digest(farURL))
            try JSONEncoder().encode(proof).write(to: proofURL, options: .atomic)
            let proofHandle = try FileHandle(forWritingTo: proofURL); try proofHandle.synchronize(); try proofHandle.close()
        }
        let result = try await service.prepareAudio(["job_id": job.id, "meeting_id": job.meetingID,
                                                     "epoch_id": payload.aecStateID ?? payload.epochID,
                                                     "sequence": payload.sequence ?? 0, "near_path": nearPath,
                                                     "far_path": farPath, "output_path": payload.relativePath,
                                                     "reset": payload.sequence == 0, "final": payload.final ?? false])
        try Task.checkCancellation()
        let output = try paths.resolveMeetingAsset(meetingID: job.meetingID, relativePath: payload.relativePath)
        let audio = try AVAudioFile(forReading: output)
        guard result.sample_rate == 16000, result.frame_count == audio.length, result.relative_path == payload.relativePath, audio.fileFormat.channelCount == 1 else { throw MeetingProcessingError.invalidResponse }
        guard result.frame_count > 0 else { return }
        let start = payload.duration == 0
            ? payload.start - Double(result.frame_count) / 16000 : payload.start
        try store.addChunk(CapturedChunk(id: job.id, meetingID: job.meetingID, epochID: payload.epochID, track: .cleanMicrophone, relativePath: payload.relativePath, startTime: start, duration: Double(result.frame_count) / 16000, sampleRate: 16000, frameCount: result.frame_count, sha256: try AudioWindowAssembler.digest(output)))
    }
    private func transcribe(job: ProcessingJob, payload: ProcessingWindow, language: String, model: SpeechRecognitionModel, liveGeneration: Int? = nil) async throws {
        let health = try await service.health()
        try checkRecognitionAdmission(meetingID: job.meetingID, generation: liveGeneration)
        guard health.canTranscribe(model) else { throw MeetingProcessingError.missingModel(model.displayName + " speech recognition (or repair the runtime)") }
        let windowChunks = try store.chunksOverlapping(meetingID: job.meetingID, track: payload.track,
                                                      start: payload.start, end: payload.start + payload.duration)
            .filter { $0.epochID == payload.epochID }
        let audio = try assembler.assemble(meetingID: job.meetingID, chunks: windowChunks, start: payload.start, duration: payload.duration, relativePath: payload.relativePath)
        guard audio.coveredFrames > 0 else { throw AudioAssemblyError.emptyAudio }
        var request: [String: Any] = ["job_id": job.id, "meeting_id": job.meetingID, "window_id": payload.windowID, "track": payload.track.rawValue, "relative_path": payload.relativePath, "start_time": payload.start, "language": language, "model": model.rawValue]
        if let configuration = payload.configuration {
            request["configuration_id"] = configuration.id
            request["transcript_version_id"] = payload.transcriptVersionID ?? "legacy-" + job.meetingID
            request["vocabulary"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration.vocabulary))
            request["fuzzy_vocabulary"] = configuration.fuzzyVocabulary
        }
        try checkRecognitionAdmission(meetingID: job.meetingID, generation: liveGeneration)
        let result = try await service.transcribe(request)
        try Task.checkCancellation()
        if let liveGeneration {
            guard liveGeneration == self.liveGeneration,
                  try store.liveTranscriptionPolicy(meetingID: job.meetingID).admitsLiveRecognition else {
                throw CancellationError()
            }
        }
        let inPerson = try store.meeting(id: job.meetingID)?.recordingMode == .inPerson
        let speakerID = ProcessingIdentity.id(job.meetingID, inPerson ? "unknown" : payload.track == .remote ? "remote" : "you")
        if try !store.speakers(meetingID: job.meetingID).contains(where: { $0.id == speakerID }) {
            try store.upsertSpeaker(Speaker(id: speakerID, meetingID: job.meetingID, label: inPerson ? "Speaker unknown" : payload.track == .remote ? "Remote speaker" : "You", isVerified: false))
        }
        var segments: [TranscriptSegment] = []
        for (index, item) in result.segments.enumerated() {
            guard item.start.isFinite, item.end.isFinite, item.start >= 0, item.end >= item.start, item.end <= audio.duration + 0.1 else { throw MeetingProcessingError.invalidResponse }
            guard !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let words = (item.words ?? []).enumerated().compactMap { position, value -> TranscriptWord? in
                let word = TranscriptWord(id: ProcessingIdentity.id(payload.windowID, String(index), "word", String(position)), text: value.text, location: value.location, length: value.length, start: payload.start + value.start, end: value.end.map { payload.start + $0 }, source: value.source, derived: value.derived, probability: value.probability)
                return word.valid(in: item.text, start: payload.start + item.start, end: payload.start + min(item.end, audio.duration)) ? word : nil
            }
            let evidence = RecognitionEvidence(originalText: item.original_text ?? item.text, confidence: item.confidence ?? [:], vocabularyEntryIDs: item.corrections?.map(\.entry_id) ?? [], sourceStart: payload.start + item.start, sourceEnd: payload.start + min(item.end, audio.duration))
            segments.append(TranscriptSegment(id: ProcessingIdentity.id(payload.windowID, String(index)), meetingID: job.meetingID, windowID: payload.windowID, track: payload.track, startTime: payload.start + item.start, endTime: payload.start + min(item.end, audio.duration), text: item.text, speakerID: speakerID, isUncertain: (item.uncertain ?? false) || !audio.isFullyCovered, isProvisional: payload.provisional, isEdited: false, words: words, recognitionEvidence: evidence))
        }
        let reconciliationChunks = try chunkSnapshot(meetingID: job.meetingID).chunks.filter {
            $0.track == payload.track && $0.epochID == payload.epochID
        }
        try saveAndReconcile(TranscriptionSnapshot(window: payload, segments: segments),
                             meetingID: job.meetingID, chunks: reconciliationChunks)
        // ASR windows are disposable; raw tracks and AEC replay inputs remain canonical.
        try? FileManager.default.removeItem(at: audio.url)
    }
    private func checkRecognitionAdmission(meetingID: String, generation: Int?) throws {
        try Task.checkCancellation()
        if let generation {
            guard generation == liveGeneration,
                  try store.liveTranscriptionPolicy(meetingID: meetingID).admitsLiveRecognition else {
                throw CancellationError()
            }
        }
    }
    private func saveAndReconcile(_ incoming: TranscriptionSnapshot, meetingID: String, chunks: [CapturedChunk]) throws {
        let snapshotURL = try paths.resolveMeetingAsset(meetingID: meetingID, relativePath: "derived/asr-result-\(incoming.window.windowID).json")
        try JSONEncoder().encode(incoming).write(to: snapshotURL, options: .atomic)
        let handle = try FileHandle(forWritingTo: snapshotURL); try handle.synchronize(); try handle.close()
        let recognitionModel: SpeechRecognitionModel = try incoming.window.configuration.map { $0.speech.id == "parakeet" ? .parakeet : .whisper } ?? (store.meeting(id: meetingID)?.recognitionModel ?? .whisper)
        let hasRedactedAudio = try store.audioRevision(meetingID: meetingID) > 0
        let completed: [CompletedSpeechWindow] = !incoming.window.provisional && incoming.window.transcriptVersionID == nil && hasRedactedAudio
            ? try store.redactions(meetingID: meetingID).flatMap(\.completedSpeechWindows) : []
        let planningChunks = RetainedSpeechCoverage.uncoveredChunks(chunks, completed: completed)
        let ownershipStart = incoming.window.ownershipStart ?? incoming.window.start
        let windows = try configuredWindows(meetingID: meetingID, chunks: planningChunks,
                                             final: !incoming.window.provisional, model: recognitionModel,
                                             configuration: incoming.window.configuration,
                                             versionID: incoming.window.transcriptVersionID,
                                             minimumOwnershipStart: max(0, ownershipStart - 28),
                                             maximumOwnershipStart: ownershipStart + 28)
        guard let currentIndex = windows.firstIndex(where: { $0.windowID == incoming.window.windowID }) else { throw MeetingProcessingError.invalidResponse }
        let nearbyWindowIDs = (max(0, currentIndex - 1)...min(windows.count - 1, currentIndex + 1)).map { windows[$0].windowID }
        let existing = try incoming.window.transcriptVersionID.map {
            try store.versionSegments(versionID: $0, windowIDs: nearbyWindowIDs)
        } ?? store.segments(meetingID: meetingID, windowIDs: nearbyWindowIDs)
        var neighbors: [TranscriptionSnapshot] = []
        for index in max(0, currentIndex - 1)...min(windows.count - 1, currentIndex + 1) {
            let window = windows[index]
            let url = try paths.resolveMeetingAsset(meetingID: meetingID, relativePath: "derived/asr-result-\(window.windowID).json")
            if FileManager.default.fileExists(atPath: url.path) {
                let snapshot = try JSONDecoder().decode(TranscriptionSnapshot.self, from: Data(contentsOf: url))
                guard snapshot.window.windowID == window.windowID, snapshot.segments.allSatisfy({ $0.meetingID == meetingID && $0.windowID == window.windowID }) else { throw MeetingProcessingError.invalidResponse }
                neighbors.append(snapshot)
            } else {
                let saved = existing.filter { $0.windowID == window.windowID }
                if !saved.isEmpty { neighbors.append(TranscriptionSnapshot(window: window, segments: saved)) }
            }
        }
        for reconciled in LexicalBoundaryReconciler.reconcile(neighbors, existing: existing) {
            // The previous window supplies context only. Rebuilding current/next
            // from original snapshots can restore words after a provisional rewrite.
            if (reconciled.window.ownershipStart ?? reconciled.window.start) >= (incoming.window.ownershipStart ?? incoming.window.start) {
                if let versionID = incoming.window.transcriptVersionID {
                    try store.saveVersionWindow(versionID: versionID, windowID: reconciled.window.windowID, segments: reconciled.segments)
                } else {
                    try store.replaceSegments(meetingID: meetingID, windowID: reconciled.window.windowID, segments: reconciled.segments, isFinal: !reconciled.window.provisional, reconcileFinal: true)
                }
            }
        }
    }
    private func execute(_ incoming: ProcessingJob, onUpdate: @escaping @Sendable (String) -> Void, operation: (ProcessingWindow) async throws -> Void) async throws {
        try Task.checkCancellation()
        var job = incoming
        job.status = .running; job.attempts += 1; job.error = nil; try store.updateJob(job)
        activeJobID = job.id
        activeJobKind = job.kind
        defer { if activeJobID == job.id { activeJobID = nil; activeJobKind = nil } }
        do {
            report("Processing \(job.kind.rawValue)…", to: onUpdate)
            try await operation(decode(job)); try Task.checkCancellation()
            job.status = .completed; try store.updateJob(job)
        } catch {
            if Task.isCancelled || error is CancellationError {
                job.status = .pending; job.attempts = max(0, job.attempts - 1); job.error = "Processing paused; saved audio is safe"
                try store.updateJob(job); throw CancellationError()
            }
            job.status = .failed; job.error = error.localizedDescription
            if error is MeetingProcessingError || error is AudioAssemblyError { job.attempts = maximumAttempts }
            try store.updateJob(job)
            report(error.localizedDescription, to: onUpdate)
        }
    }

    private func runFinalization(meetingID: String, diarizationWindowSeconds: Int?, onUpdate: @escaping @Sendable (String) -> Void) async throws {
        guard var meeting = try store.meeting(id: meetingID) else { throw MeetingProcessingError.meetingUnavailable }
        meeting.state = .finalizing; if meeting.endedAt == nil { meeting.endedAt = Date() }; try store.updateMeeting(meeting)
        do {
            // Explicit finalization is also an explicit retry, with a new bounded budget.
            for var job in try store.jobs(meetingID: meetingID)
                where job.status == .failed || (job.status == .pending && job.attempts >= maximumAttempts) {
                job.status = .pending; job.attempts = 0; try store.updateJob(job)
            }
            let activeVersion = try store.activeTranscriptVersion(meetingID: meetingID)
            let completedVersion = try store.transcriptVersions(meetingID: meetingID).contains { $0.id == activeVersion && $0.status == .ready }
            let reuseRedactedTranscript = try store.canReuseTranscriptAfterRedaction(meetingID: meetingID)
            let reuseRetainedTranscript = completedVersion || reuseRedactedTranscript
            // A reviewed/generated version is immutable ASR input for downstream work.
            // Only Regenerate creates another transcript; Generate / Retry must not mix windows.
            if !reuseRetainedTranscript {
                while try await processAudio(meetingID: meetingID, final: true, onUpdate: onUpdate) {
                    try Task.checkCancellation()
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
            } else {
                while try await processAudio(meetingID: meetingID, final: true, prepareOnly: true, onUpdate: onUpdate) {
                    try Task.checkCancellation()
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            // A ready redacted meeting already has verified retained clean chunks.
            // Its old AEC proofs were retired with the deleted interval; replaying
            // those jobs against the surviving output would be both invalid and
            // unnecessary. The coverage audit below still detects any missing part.
            if try !store.speakerphoneMicrophoneChunks(meetingID: meetingID).isEmpty { try auditPreparedCoverage(meetingID: meetingID) }
            // The speech model must release memory before diarization or Swift MLX.
            await service.unload()
            try Task.checkCancellation()
            let remote = try store.chunks(meetingID: meetingID, track: meeting.recordingMode.groupingTrack)
            let configuration = try store.transcriptVersions(meetingID: meetingID).first(where: { $0.id == activeVersion })?.configuration ?? store.configuration(meetingID: meetingID)
            if !remote.isEmpty && (configuration == nil || configuration?.speakers != nil) {
                var payload = ProcessingIdentity.diarizationWindow(meetingID: meetingID, chunks: remote, windowSeconds: diarizationWindowSeconds, track: meeting.recordingMode.groupingTrack, versionID: activeVersion)
                payload.speakerModel = configuration?.speakers
                if let selection = payload.speakerModel { payload.windowID = ProcessingIdentity.id(payload.windowID, selection.id, selection.revision) }
                let desiredID = ProcessingIdentity.jobID(payload, kind: .diarize)
                for var old in try store.jobs(meetingID: meetingID) where old.kind == .diarize && old.id != desiredID && old.status != .completed {
                    old.status = .cancelled; old.error = "Superseded by the selected speaker-separation mode"; try store.updateJob(old)
                }
                try enqueue(payload, kind: .diarize, meetingID: meetingID)
                if let job = try store.jobs(meetingID: meetingID).first(where: { $0.id == ProcessingIdentity.jobID(payload, kind: .diarize) }), job.status != .completed {
                    try await execute(job, onUpdate: onUpdate) { payload in try await self.diarize(job: job, payload: payload, remote: remote) }
                }
                // A recovered ASR window can replace generic assignments after this job completed.
                // Reuse persisted turns; no extra model run and no changes to reviewed identities.
                if let run = try store.speakerGroupingRuns(meetingID: meetingID).first(where: { $0.id == payload.windowID }) {
                    let genericID = ProcessingIdentity.id(meetingID, meeting.recordingMode == .inPerson ? "unknown" : "remote")
                    var assignments: [String: String] = [:]
                    for segment in try store.segments(meetingID: meetingID) where segment.track == run.track && (segment.speakerID == nil || segment.speakerID == genericID) {
                        var overlaps: [String: Double] = [:]
                        for turn in run.turns {
                            overlaps[turn.speakerID, default: 0] += max(0, min(segment.endTime, turn.end) - max(segment.startTime, turn.start))
                        }
                        if let best = overlaps.filter({ $0.value > 0 }).sorted(by: { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }).first { assignments[segment.id] = best.key }
                    }
                    if !assignments.isEmpty { try store.saveSpeakerGrouping(run, assignments: assignments, reapply: true) }
                }
            }
            try Task.checkCancellation()
            guard let refreshed = try store.meeting(id: meetingID) else { throw MeetingProcessingError.meetingUnavailable }
            let segments = try store.segments(meetingID: meetingID)
            let evidenceVersion = ProcessingIdentity.id([String(refreshed.transcriptRevision)] + segments.filter { !$0.isProvisional }.map { $0.id + ":" + $0.text + ":" + ($0.speakerID ?? "") + ":" + String($0.isUncertain) })
            let notesSelection = configuration?.notes ?? (configuration == nil ? ModelSelection(id: "notes", revision: "legacy") : nil)
            if let notesSelection {
            let notesQueue = NotesGenerationQueue(store: store)
            let job = try notesQueue.enqueue(meetingID: meetingID, evidenceVersion: ProcessingIdentity.id(evidenceVersion, notesSelection.provider.rawValue, notesSelection.id, notesSelection.revision))
            if canRun(job) {
                try await execute(job, onUpdate: onUpdate) { _ in
                    guard await self.intelligence.ready(notesSelection) else { throw MeetingProcessingError.missingModel("notes") }
                    var notes = try await self.intelligence.generateNotes(meeting: refreshed, segments: segments, selection: notesSelection, onProgress: onUpdate)
                    notes.transcriptVersionID = try self.store.activeTranscriptVersion(meetingID: meetingID)
                    try Task.checkCancellation()
                    let failed = try self.store.jobs(meetingID: meetingID).contains {
                        $0.kind != .notes && [.failed, .pending, .running].contains($0.status)
                    }
                    try notesQueue.save(notes, job: job, hasIncompleteEvidence: failed)
                }
            }
            }
            await intelligence.releaseCache()
            let failed = try store.jobs(meetingID: meetingID).filter { job in
                guard job.kind == .transcribe || job.kind == .prepareAudio else { return false }
                if job.kind == .transcribe, reuseRetainedTranscript { return false }
                return [.failed, .pending, .running].contains(job.status)
            }
            if failed.isEmpty { try? cleanupFinalizedAEC(meetingID: meetingID) }
            if var latest = try store.meeting(id: meetingID) { latest.state = failed.isEmpty ? .ready : .failed; try store.updateMeeting(latest) }
            if !failed.isEmpty { throw MeetingProcessingError.stagesFailed(Array(Set(failed.map { $0.error ?? $0.kind.rawValue + " is blocked by an earlier audio preparation failure" })).sorted()) }
            onUpdate("Meeting processing complete")
        } catch {
            await service.unload(); await intelligence.releaseCache()
            if var latest = try? store.meeting(id: meetingID) { latest.state = Task.isCancelled ? .interrupted : .failed; try? store.updateMeeting(latest) }
            throw error
        }
    }
    private struct AECFinalizedReceipt: Decodable {
        let journal_sha256: String
        let jobs: [String]
    }

    private func cleanupFinalizedAEC(meetingID: String) throws {
        let jobs = try store.jobs(meetingID: meetingID).filter { $0.kind == .prepareAudio }
        let windows = jobs.compactMap { job -> (ProcessingJob, ProcessingWindow)? in
            guard let window = try? decode(job), window.sequence != nil else { return nil }
            return (job, window)
        }
        let microphone = try store.speakerphoneMicrophoneChunks(meetingID: meetingID)
        let clean = try store.chunks(meetingID: meetingID, track: .cleanMicrophone)
        for (stateID, items) in Dictionary(grouping: windows, by: { $0.1.aecStateID ?? $0.1.epochID }) {
            guard let epoch = items.first?.1.epochID else { continue }
            guard items.contains(where: { $0.1.final == true && $0.0.status == .completed }),
                  items.allSatisfy({ $0.0.status == .completed }),
                  AECCoverageAudit.uncovered(near: microphone.filter { $0.epochID == epoch },
                                             clean: clean.filter { $0.epochID == epoch }).isEmpty else { continue }
            let journal = try paths.resolveMeetingAsset(meetingID: meetingID, relativePath: "derived/.aec/\(stateID).json")
            let receiptURL = try paths.resolveMeetingAsset(meetingID: meetingID, relativePath: "derived/.aec/\(stateID).finalized.json")
            guard FileManager.default.fileExists(atPath: journal.path),
                  FileManager.default.fileExists(atPath: receiptURL.path),
                  let receipt = try? JSONDecoder().decode(AECFinalizedReceipt.self, from: Data(contentsOf: receiptURL)),
                  try AudioWindowAssembler.digest(journal) == receipt.journal_sha256,
                  Set(receipt.jobs) == Set(items.map { $0.0.id }) else { continue }
            for chunk in clean.filter({ $0.epochID == epoch }) {
                let lease = try store.audioAssets.acquireSync(chunk: chunk)
                guard try AudioWindowAssembler.digest(lease.url).caseInsensitiveCompare(chunk.sha256) == .orderedSame else {
                    throw MeetingProcessingError.invalidResponse
                }
            }
            for (_, window) in items {
                for path in ["derived/aec-near-\(window.windowID).wav",
                             "derived/aec-far-\(window.windowID).wav",
                             "derived/aec-input-\(window.windowID).json"] {
                    let file = try paths.resolveMeetingAsset(meetingID: meetingID, relativePath: path)
                    if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
                }
            }
        }
    }
    func auditPreparedCoverage(meetingID: String) throws {
        let near = try store.speakerphoneMicrophoneChunks(meetingID: meetingID)
        let clean = try store.chunks(meetingID: meetingID, track: .cleanMicrophone)
        let missing = AECCoverageAudit.uncovered(near: near, clean: clean)
        var currentIDs = Set<String>()
        for interval in missing {
            let identity = ProcessingIdentity.id(meetingID, "aec-coverage", interval.epochID, String(interval.start.bitPattern), String(interval.end.bitPattern))
            let payload = ProcessingWindow(track: .microphone, epochID: "aec-coverage:" + interval.epochID, start: interval.start, duration: interval.end - interval.start, windowID: identity, provisional: false, relativePath: "")
            try enqueue(payload, kind: .prepareAudio, meetingID: meetingID)
            let jobID = ProcessingIdentity.jobID(payload, kind: .prepareAudio)
            currentIDs.insert(jobID)
            let message = String(format: "Microphone transcript unavailable from %.2f to %.2f seconds: matching echo-reference or prepared audio is missing. Raw microphone audio is retained for playback and export.", interval.start, interval.end)
            if var job = try store.jobs(meetingID: meetingID).first(where: { $0.id == jobID }) {
                job.status = .failed; job.attempts = maximumAttempts; job.error = message; try store.updateJob(job)
            }
            try store.addGap(CaptureGap(id: identity, meetingID: meetingID, startTime: interval.start, endTime: interval.end, reason: message))
        }
        for var job in try store.jobs(meetingID: meetingID) where job.kind == .prepareAudio {
            guard let payload = try? decode(job), payload.epochID == "missing-reference" || payload.epochID.hasPrefix("aec-coverage:"), !currentIDs.contains(job.id) else { continue }
            job.status = .cancelled; job.error = "Resolved: microphone transcript input now covers this interval"; try store.updateJob(job)
            if payload.epochID.hasPrefix("aec-coverage:") {
                try store.addGap(CaptureGap(id: payload.windowID, meetingID: meetingID, startTime: payload.start, endTime: payload.start + payload.duration, reason: "Resolved processing gap: microphone transcript input was recovered; raw audio was retained."))
            }
        }
    }

    private func recordFailure(meetingID: String, kind: JobKind, label: String, message: String) throws {
        let payload = ProcessingWindow(track: .microphone, epochID: label, start: 0, duration: 0, windowID: ProcessingIdentity.id(meetingID, label), provisional: false, relativePath: "")
        try enqueue(payload, kind: kind, meetingID: meetingID)
        if var job = try store.jobs(meetingID: meetingID).first(where: { $0.id == ProcessingIdentity.jobID(payload, kind: kind) }) {
            job.status = .failed; job.attempts = maximumAttempts; job.error = message; try store.updateJob(job)
        }
    }
    private func diarize(job: ProcessingJob, payload: ProcessingWindow, remote: [CapturedChunk]) async throws {
        let health = try await service.health()
        guard payload.speakerModel?.id == "community1" ? health.models["community1"]?.ready == true : health.capabilities.diarize else { throw MeetingProcessingError.missingModel("speaker separation") }
        let fullURL = try paths.resolveMeetingAsset(meetingID: job.meetingID, relativePath: payload.relativePath)
        defer { try? FileManager.default.removeItem(at: fullURL) }
        _ = try assembler.assembleFull(meetingID: job.meetingID, chunks: remote, relativePath: payload.relativePath)
        try Task.checkCancellation()
        let result = try await service.diarize(["job_id": job.id, "meeting_id": job.meetingID, "relative_path": payload.relativePath, "model": payload.speakerModel?.id ?? "diarization", "window_seconds": payload.windowSeconds.map { $0 as Any } ?? NSNull()])
        try Task.checkCancellation()
        let end = remote.map { $0.startTime + $0.duration }.max() ?? 0
        guard result.turns.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start && $0.end <= end + 0.1 && !$0.speaker.isEmpty }) else { throw MeetingProcessingError.invalidResponse }
        var labels: [String] = []
        for turn in result.turns.sorted(by: { $0.start == $1.start ? $0.speaker < $1.speaker : $0.start < $1.start }) where !labels.contains(turn.speaker) { labels.append(turn.speaker) }
        let inPerson = payload.track == .microphone
        let existing = try store.speakers(meetingID: job.meetingID)
        for (index, label) in labels.enumerated() {
            let id = ProcessingIdentity.id(job.meetingID, "diarized", payload.windowID, label)
            if !existing.contains(where: { $0.id == id }) {
                try store.upsertSpeaker(Speaker(id: id, meetingID: job.meetingID, label: result.partial ? "\(inPerson ? "Speaker" : "Remote") \(label) (window-scoped)" : "\(inPerson ? "Speaker" : "Remote speaker") \(index + 1)", isVerified: false))
            }
        }
        let segments = try store.segments(meetingID: job.meetingID).filter { $0.track == payload.track }
        var assignments: [String: String] = [:]
        for index in segments.indices {
            let segment = segments[index]
            var overlaps: [String: Double] = [:]
            for turn in result.turns {
                let overlap = max(0, min(segment.endTime, turn.end) - max(segment.startTime, turn.start))
                if overlap > 0 { overlaps[turn.speaker, default: 0] += overlap }
            }
            let ranked = overlaps.sorted { $0.value > $1.value }
            if let best = ranked.first {
                assignments[segment.id] = ProcessingIdentity.id(job.meetingID, "diarized", payload.windowID, best.key)
            }
        }
        let versionID = try payload.transcriptVersionID ?? store.activeTranscriptVersion(meetingID: job.meetingID)
        try store.saveSpeakerGrouping(.init(id: payload.windowID, meetingID: job.meetingID, transcriptVersionID: versionID, track: payload.track, model: payload.speakerModel, audioFingerprint: ProcessingIdentity.recordingFingerprint(remote), partial: result.partial, turns: result.turns.map { SpeakerTurn(start: $0.start, end: $0.end, speakerID: ProcessingIdentity.id(job.meetingID, "diarized", payload.windowID, $0.speaker)) }), assignments: assignments)
    }
}
