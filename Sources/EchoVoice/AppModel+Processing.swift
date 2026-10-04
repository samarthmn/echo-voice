import Foundation
import SwiftUI
import AppKit
import AVFoundation
import EchoCore
import EchoCapture
import EchoRuntime
import EchoIntelligence

extension AppModel {
    func processMeeting(_ id: String, windowedSpeakers: Bool = false) {
        guard !assetWorkBlocked(id), let store, !pendingRedactionMeetings.contains(id) else { return }
        do {
            try store.enqueueProcessing(meetingID: id, windowedSpeakers: windowedSpeakers)
            processingEvents[id] = .init(meetingID: id, stage: .queued, message: "Waiting to process")
            drainProcessingQueue()
        } catch { self.error = error.localizedDescription }
    }

    func drainProcessingQueue() {
        queuedProcessing = (try? store?.processingQueue()) ?? []
        guard !isShuttingDown, !isRecording, !changingRecording, !setupBusy,
              !redactionBusy, processingID == nil, inferenceHandoff == nil,
              let store, let processor,
              let request = queuedProcessing.first(where: {
                  !recoveringAssetMeetings.contains($0.meetingID) && !damagedAssetMeetings.contains($0.meetingID)
                    && !pendingMeetingDeletions.contains($0.meetingID) && !deletingMeetings.contains($0.meetingID)
                    && !pendingRedactionMeetings.contains($0.meetingID)
                    && self.queuedModelsAllowProgress($0)
              }) else { return }
        let id = request.meetingID
        processingID = id
        processingGeneration += 1
        let generation = processingGeneration
        processingEvents[id] = .init(meetingID: id, stage: .preparing, message: "Preparing saved audio")
        processingTask = Task { [self] in
            defer {
                if processingGeneration == generation {
                    processingID = nil
                    reload(); reloadDetail()
                    activateStagedDownloads()
                    drainProcessingQueue()
                }
            }
            do {
                try await mutationCoordinator.withLease(meetingID: id, access: .exclusive) {
                    try await processor.finalize(meetingID: id, diarizationWindowSeconds: request.windowedSpeakers ? 1800 : nil, onEvent: { [weak self] event in
                        Task { @MainActor in
                            guard let self, self.processingGeneration == generation else { return }
                            self.processingEvents[id] = event
                        }
                    }) { [weak self] message in
                        Task { @MainActor in
                            guard let self, self.processingGeneration == generation else { return }
                            self.processingEvents[id] = .init(meetingID: id, stage: self.processingEvents[id]?.stage ?? .preparing, message: message)
                            self.scheduleRefresh()
                        }
                    }
                }
                try Task.checkCancellation()
                try store.finishQueuedProcessing(meetingID: id)
                processingEvents[id] = .init(meetingID: id, stage: .ready, message: "Ready to review")
                scheduleCompaction(for: [id])
            } catch is CancellationError {
                // Cancellation checkpoints individual jobs and retains queue intent.
                processingEvents[id] = .init(meetingID: id, stage: .queued, message: "Waiting until recording finishes")
            } catch {
                if !missingProcessingModels(id).isEmpty {
                    try? store.waitForProcessingModels(meetingID: id)
                    processingEvents[id] = .init(meetingID: id, stage: .queued, message: "Waiting for model setup: " + missingProcessingModels(id).joined(separator: ", "))
                } else {
                    // Non-model failures require an explicit retry, not an endless loop.
                    try? store.finishQueuedProcessing(meetingID: id)
                    processingEvents[id] = .init(meetingID: id, stage: .needsAttention, message: error.localizedDescription)
                }
            }
        }
    }

    func missingProcessingModels(_ id: String) -> [String] {
        guard let meeting = try? store?.meeting(id: id) else { return [] }
        let context = try? store?.finalizationContext(meetingID: id)
        let configuration = context?.configuration
        var missing: [String] = []
        if context?.reusesTranscript != true && health?.canTranscribe(meeting.recognitionModel) != true { missing.append(meeting.recognitionModel.displayName) }
        let hasGroupingAudio = ((try? store?.chunks(meetingID: id, track: meeting.recordingMode.groupingTrack).isEmpty) == false)
        let notes = configuration?.notes ?? (configuration == nil ? .init(id: "notes", revision: "legacy") : nil)
        let speakers = hasGroupingAudio ? configuration?.speakers ?? (configuration == nil ? .init(id: "diarization", revision: "legacy") : nil) : nil
        let selections = [notes, speakers].compactMap { $0 }
        for selection in selections {
            let ready: Bool
            if selection.provider == .ollama {
                ready = ollamaModels.contains { $0.name == selection.id && $0.digest == selection.revision }
            } else {
                ready = health?.models[selection.id]?.ready == true && (selection.revision == "legacy" || health?.models[selection.id]?.revision == selection.revision)
            }
            if !ready { missing.append(catalog?.model(selection.id)?.displayName ?? selection.id) }
        }
        return missing
    }

    func queuedModelsAllowProgress(_ request: QueuedProcessing) -> Bool {
        guard let meeting = try? store?.meeting(id: request.meetingID) else { return false }
        let missing = missingProcessingModels(request.meetingID)
        let reuse = (try? store?.finalizationContext(meetingID: request.meetingID).reusesTranscript) == true
        let speechMissing = !reuse && health?.canTranscribe(meeting.recognitionModel) != true
        if speechMissing || (request.waitingForModels && !missing.isEmpty) {
            processingEvents[request.meetingID] = .init(meetingID: request.meetingID, stage: .queued,
                message: "Waiting for model setup: " + missing.joined(separator: ", "))
            return false
        }
        return true
    }

    func scheduleCompaction(for meetingIDs: [String]) {
        let eligible = meetingIDs.filter { !pendingMeetingDeletions.contains($0) && !deletingMeetings.contains($0) }
        guard let store, !eligible.isEmpty else { return }
        let coordinator = mutationCoordinator
        compactionTask?.cancel()
        compactionTask = Task.detached(priority: .utility) {
            let compactor = AudioCompactor(store: store)
            for id in eligible {
                guard !Task.isCancelled else { return }
                _ = try? await coordinator.withLease(meetingID: id, access: .exclusive) {
                    try await compactor.compact(meetingID: id)
                }
            }
        }
    }

}
