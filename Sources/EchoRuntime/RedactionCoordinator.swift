import Foundation
import AVFoundation
import Darwin
import EchoCore

public actor RedactionCoordinator {
    private let store: MeetingStore
    private let paths: AppPaths

    public init(store: MeetingStore, paths: AppPaths) {
        self.store = store; self.paths = paths
    }

    public func preview(meetingID: String, segmentID: String) throws -> RedactionPreview {
        try store.redactionPreview(meetingID: meetingID, segmentID: segmentID)
    }

    public func commit(preview: RedactionPreview) throws {
        let current = try store.redactionPreview(meetingID: preview.meetingID, segmentID: preview.segmentID)
        guard current == preview else {
            throw EchoCoreError.invalidValue("the passage changed; review deletion again")
        }
        let allChunks = try store.chunks(meetingID: preview.meetingID)
        let microphone = allChunks.filter { $0.track == .microphone }
        var epochSplits: [String: String] = [:]
        for (epoch, chunks) in Dictionary(grouping: microphone, by: \.epochID) {
            if chunks.contains(where: { $0.startTime < preview.start }) &&
                chunks.contains(where: { $0.startTime + $0.duration > preview.end }) {
                epochSplits[epoch] = "redacted-\(UUID().uuidString)"
            }
        }
        let old = allChunks.filter {
            $0.startTime < preview.end && $0.startTime + $0.duration > preview.start
            || ($0.track == .cleanMicrophone && epochSplits[$0.epochID] != nil &&
                $0.startTime + $0.duration > preview.start)
        }
        let priorSegments = try store.segments(meetingID: preview.meetingID)
        let preserveTranscript = try store.meeting(id: preview.meetingID)?.state == .ready &&
            priorSegments.allSatisfy { !$0.isProvisional }
        var completedSpeechWindows = try store.jobs(meetingID: preview.meetingID).compactMap { job -> CompletedSpeechWindow? in
            guard job.kind == .transcribe, job.status == .completed,
                  let window = try? JSONDecoder().decode(ProcessingWindow.self, from: Data(job.payload.utf8)),
                  !window.provisional, window.transcriptVersionID == nil else { return nil }
            return CompletedSpeechWindow(windowID: window.windowID, track: window.track,
                                         epochID: window.epochID,
                                         ownershipStart: window.ownershipStart ?? window.start,
                                         ownershipEnd: window.ownershipEnd ?? window.start + window.duration)
        }
        completedSpeechWindows = RetainedSpeechCoverage.extending(completedSpeechWindows,
            with: priorSegments, excluding: preview.start..<preview.end)
        // Human corrections to a live preview survive a retry. Its unedited
        // machine text is disposable and will be removed on publication.
        for segment in priorSegments where segment.isEdited && segment.isProvisional &&
            !(segment.startTime < preview.end && segment.endTime > preview.start) {
            completedSpeechWindows.append(CompletedSpeechWindow(windowID: segment.windowID,
                track: segment.track, epochID: "edited-preview", ownershipStart: segment.startTime,
                ownershipEnd: segment.endTime))
        }
        let intent = AudioRedaction(meetingID: preview.meetingID, start: preview.start,
                                    end: preview.end, oldChunks: old, epochSplits: epochSplits,
                                    preserveExistingTranscript: preserveTranscript,
                                    completedSpeechWindows: completedSpeechWindows)
        try store.saveRedactionIntent(intent)
        try resume(intent)
    }

    public func recoverPending() throws {
        for intent in try store.pendingRedactions() { try resume(intent) }
    }

    public func recoverPending(meetingID: String) throws {
        for intent in try store.pendingRedactions() where intent.meetingID == meetingID {
            try resume(intent)
        }
    }

    private func resume(_ saved: AudioRedaction) throws {
        var redaction = saved
        if redaction.state == .intent {
            var retained: [CapturedChunk] = []
            for chunk in redaction.oldChunks {
                retained += try rewrite(chunk: chunk, redaction: redaction)
            }
            redaction.newChunks = retained
            redaction.state = .staged
            try store.saveStagedRedaction(redaction)
        }
        if redaction.state == .staged {
            try store.publishRedaction(redaction)
            redaction.state = .published
        }
        if redaction.state == .published {
            try purgeSuperseded(redaction)
            try store.completeRedaction(redaction)
        }
    }

    private func rewrite(chunk: CapturedChunk, redaction: AudioRedaction) throws -> [CapturedChunk] {
        let lease = try store.audioAssets.acquireSync(chunk: chunk)
        let original = try AVAudioFile(forReading: lease.url)
        let common = original.fileFormat.commonFormat
        guard common == .pcmFormatFloat32 || common == .pcmFormatInt16,
              original.length > 0, original.length <= 30 * 192_000 * 8 else {
            throw EchoCoreError.invalidValue("audio format cannot be trimmed without changing retained samples")
        }
        let reader = try AVAudioFile(forReading: lease.url, commonFormat: common, interleaved: false)
        let total = Int(reader.length)
        guard let whole = AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: AVAudioFrameCount(total)) else {
            throw EchoCoreError.invalidValue("audio buffer")
        }
        var copied = 0
        while copied < total {
            let capacity = min(16_384, total - copied)
            guard let portion = AVAudioPCMBuffer(pcmFormat: reader.processingFormat,
                                                  frameCapacity: AVAudioFrameCount(capacity)) else {
                throw EchoCoreError.invalidValue("audio buffer")
            }
            try reader.read(into: portion, frameCount: AVAudioFrameCount(capacity))
            let count = Int(portion.frameLength)
            guard count > 0 else { break }
            let channels = Int(reader.processingFormat.channelCount)
            if common == .pcmFormatFloat32,
               let source = portion.floatChannelData, let destination = whole.floatChannelData {
                for channel in 0..<channels {
                    memcpy(destination[channel].advanced(by: copied), source[channel], count * MemoryLayout<Float>.size)
                }
            } else if common == .pcmFormatInt16,
                      let source = portion.int16ChannelData, let destination = whole.int16ChannelData {
                for channel in 0..<channels {
                    memcpy(destination[channel].advanced(by: copied), source[channel], count * MemoryLayout<Int16>.size)
                }
            } else { throw EchoCoreError.invalidValue("audio format") }
            copied += count
        }
        guard copied == total else {
            throw EchoCoreError.invalidValue("audio length changed (\(chunk.id): \(copied) of \(total) frames)")
        }
        whole.frameLength = AVAudioFrameCount(total)
        let fractionStart = max(0, min(1, (redaction.start - chunk.startTime) / chunk.duration))
        let fractionEnd = max(0, min(1, (redaction.end - chunk.startTime) / chunk.duration))
        let leftFrames = max(0, min(total, Int(floor(fractionStart * Double(total)))))
        let rightFrame = max(leftFrames, min(total, Int(ceil(fractionEnd * Double(total)))))
        var result: [CapturedChunk] = []
        func writePart(_ label: String, offset: Int, count: Int) throws {
            guard count > 0 else { return }
            let id = "redacted-\(redaction.id)-\(chunk.id)-\(label)"
            let ext = URL(fileURLWithPath: chunk.relativePath).pathExtension
            let relativePath = "audio/\(id).\(ext.isEmpty ? "caf" : ext)"
            let url = try paths.resolveMeetingAsset(meetingID: chunk.meetingID, relativePath: relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: url)
            guard let part = AVAudioPCMBuffer(pcmFormat: reader.processingFormat,
                                              frameCapacity: AVAudioFrameCount(count)) else {
                throw EchoCoreError.invalidValue("audio buffer")
            }
            part.frameLength = AVAudioFrameCount(count)
            let channels = Int(reader.processingFormat.channelCount)
            if common == .pcmFormatFloat32,
               let source = whole.floatChannelData, let destination = part.floatChannelData {
                for channel in 0..<channels {
                    memcpy(destination[channel], source[channel].advanced(by: offset), count * MemoryLayout<Float>.size)
                }
            } else if common == .pcmFormatInt16,
                      let source = whole.int16ChannelData, let destination = part.int16ChannelData {
                for channel in 0..<channels {
                    memcpy(destination[channel], source[channel].advanced(by: offset), count * MemoryLayout<Int16>.size)
                }
            } else { throw EchoCoreError.invalidValue("audio format") }
            do {
                let writer = try AVAudioFile(forWriting: url, settings: original.fileFormat.settings,
                                             commonFormat: common, interleaved: false)
                try writer.write(from: part)
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.synchronize(); try handle.close()
            try synchronizeDirectory(url.deletingLastPathComponent())
            let start = chunk.startTime + chunk.duration * Double(offset) / Double(total)
            let duration = chunk.duration * Double(count) / Double(total)
            let outputEpoch = chunk.track == .microphone && label == "after"
                ? (redaction.epochSplits[chunk.epochID] ?? chunk.epochID) : chunk.epochID
            result.append(CapturedChunk(id: id, meetingID: chunk.meetingID, epochID: outputEpoch,
                                        track: chunk.track, relativePath: relativePath, startTime: start,
                                        duration: duration, sampleRate: chunk.sampleRate,
                                        frameCount: Int64(count), sha256: try AudioWindowAssembler.digest(url)))
        }
        if chunk.track != .cleanMicrophone || redaction.epochSplits[chunk.epochID] == nil {
            try writePart("before", offset: 0, count: leftFrames)
            try writePart("after", offset: rightFrame, count: total - rightFrame)
        } else if chunk.startTime < redaction.start {
            try writePart("before", offset: 0, count: leftFrames)
        }
        return result
    }

    private func purgeSuperseded(_ redaction: AudioRedaction) throws {
        for chunk in redaction.oldChunks {
            try store.audioAssets.purgeDeleted(chunk: chunk)
        }
        let derived = paths.meetingDirectory(redaction.meetingID).appendingPathComponent("derived", isDirectory: true)
        guard FileManager.default.fileExists(atPath: derived.path) else { return }
        let retained = try store.chunks(meetingID: redaction.meetingID)
            .reduce(into: Set<String>()) { paths, chunk in
                paths.formUnion(try store.audioAssets.managedPaths(chunk: chunk))
            }
        guard let enumerator = FileManager.default.enumerator(at: derived, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw EchoCoreError.invalidValue("could not inspect derived audio for deletion")
        }
        var changedDirectories = Set<URL>()
        for case let file as URL in enumerator {
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let relative = "derived/" + file.path.replacingOccurrences(of: derived.path + "/", with: "")
            if !retained.contains(relative) {
                try FileManager.default.removeItem(at: file)
                changedDirectories.insert(file.deletingLastPathComponent())
            }
        }
        for directory in changedDirectories { try synchronizeDirectory(directory) }
    }

    private func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
