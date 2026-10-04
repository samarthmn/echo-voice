import Foundation
import SwiftUI
import AppKit
import AVFoundation
import EchoCore
import EchoCapture
import EchoRuntime
import EchoIntelligence

extension AppModel {
    func saveAnnotation(_ annotation: TranscriptAnnotation) {
        do { try store?.saveAnnotation(annotation); reloadDetail() } catch { self.error = error.localizedDescription }
    }
    func removeAnnotation(_ annotation: TranscriptAnnotation) {
        do { try store?.removeAnnotation(id: annotation.id, meetingID: annotation.meetingID); reloadDetail() } catch { self.error = error.localizedDescription }
    }
    func bookmark(at time: Double? = nil) {
        guard let id = selectedID, !isRecording else { return }
        do { try store?.saveAnnotation(.init(meetingID: id, kind: .bookmark, track: playbackTrack, startTime: time ?? playbackTime)); reloadDetail() } catch { self.error = error.localizedDescription }
    }
    func highlight(_ segment: TranscriptSegment, range: NSRange) {
        guard !segment.isProvisional, range.length > 0, range.location >= 0, NSMaxRange(range) <= (segment.text as NSString).length, let store else { return }
        do {
            let version = try store.activeTranscriptVersion(meetingID: segment.meetingID)
            if let existing = annotations.first(where: { $0.kind == .highlight && $0.transcriptVersionID == version && $0.segmentID == segment.id && $0.location == range.location && $0.length == range.length }) { try store.removeAnnotation(id: existing.id, meetingID: segment.meetingID) }
            else {
                let words = (segment.words ?? []).filter { NSIntersectionRange($0.range, range).length > 0 }
                try store.saveAnnotation(.init(meetingID: segment.meetingID, kind: .highlight, transcriptVersionID: version, segmentID: segment.id, location: range.location, length: range.length, quote: (segment.text as NSString).substring(with: range), track: segment.track, startTime: words.first?.start ?? segment.startTime, endTime: words.last?.end ?? segment.endTime))
            }
            reloadDetail()
        } catch { self.error = error.localizedDescription }
    }
    func isAudible(_ track: AudioTrack) -> Bool {
        if let playbackTrack { return playbackTrack == track }
        return track == .remote || track == (selectedMeeting?.usesEchoCancellation == true ? .cleanMicrophone : .microphone)
    }

    func regenerateTranscript(speech: SpeechRecognitionModel, useVocabulary: Bool, meetingID: String? = nil) {
        guard meetingID == nil || meetingID == selectedID else { return }
        if let id = selectedID, assetWorkBlocked(id) { return }
        guard let id = selectedID, let processor, modelChangesAllowed,
              !redactionBusy, !pendingRedactionMeetings.contains(id) else { return }
        processingID = id
        processingTask = Task {
            defer { processingID = nil; reloadDetail(); activateStagedDownloads(); startNextDownload(); drainProcessingQueue() }
            do {
                let configuration = try processingConfiguration(speech: speech, includeVocabulary: useVocabulary)
                let version = try await mutationCoordinator.withLease(meetingID: id, access: .exclusive) { [weak self] in
                    try await processor.regenerate(meetingID: id, configuration: configuration) { [weak self] message in
                        Task { @MainActor in self?.status = message }
                    }
                }
                // Explicit activation also protects edits in an open transcript editor.
                if selectedID == id { readyTranscriptID = version }; status = "New transcript ready. Switch when you finish reviewing."
            } catch is CancellationError { status = "Regeneration cancelled. Previous transcript retained." }
            catch { self.error = error.localizedDescription }
        }
    }
    func activateTranscript(_ version: String, meetingID: String? = nil) {
        guard meetingID == nil || meetingID == selectedID else { return }
        guard let id = selectedID, !isRecording, !playing, !redactionBusy,
              !pendingRedactionMeetings.contains(id), processingID == nil else { return }
        do { stopPlayback(); try store?.activateTranscriptVersion(version, meetingID: id); readyTranscriptID = nil; reload(); reloadDetail(); search() }
        catch { self.error = error.localizedDescription }
    }

    func editSegment(_ segment: TranscriptSegment, text: String, versionID: String? = nil) {
        if let versionID, (try? store?.activeTranscriptVersion(meetingID: segment.meetingID)) != versionID {
            error = "The transcript version changed. Reopen this passage to edit it."; return
        }
        guard !redactionBusy, !pendingRedactionMeetings.contains(segment.meetingID) else { return }
        do { try store?.editSegment(id: segment.id, text: text); reload(); reloadDetail(); search() }
        catch { self.error = error.localizedDescription }
    }
    func previewPassageDeletion(_ segment: TranscriptSegment) async -> RedactionPreview? {
        guard !assetWorkBlocked(segment.meetingID) else { return nil }
        guard !isRecording, !redactionBusy, !pendingRedactionMeetings.contains(segment.meetingID), let redactor else { return nil }
        do { return try await redactor.preview(meetingID: segment.meetingID, segmentID: segment.id) }
        catch { self.error = error.localizedDescription; return nil }
    }

    func deletePassageAndAudio(_ preview: RedactionPreview) async {
        guard !assetWorkBlocked(preview.meetingID) else { return }
        guard !isRecording, !redactionBusy, let redactor else { return }
        redactionBusy = true
        pendingRedactionMeetings.insert(preview.meetingID)
        defer { redactionBusy = false; reload(); reloadDetail(); search(); activateStagedDownloads(); drainProcessingQueue() }
        processingTask?.cancel()
        await processor?.cancel()
        await processingTask?.value
        compactionTask?.cancel()
        await compactionTask?.value
        await exportTask?.value
        stopPlayback(); player = nil
        do {
            try await mutationCoordinator.withLease(meetingID: preview.meetingID, access: .exclusive) {
                try await redactor.commit(preview: preview)
            }
            pendingRedactionMeetings.remove(preview.meetingID)
            status = "Passage and managed audio deleted."
        } catch {
            pendingRedactionMeetings = Set((try? store?.pendingRedactions().map(\.meetingID)) ?? [])
            self.error = pendingRedactionMeetings.contains(preview.meetingID)
                ? "Passage deletion needs recovery: " + error.localizedDescription
                : error.localizedDescription
        }
    }

    func retryPendingRedactions() {
        guard !redactionBusy, let redactor else { return }
        redactionBusy = true
        Task {
            defer { redactionBusy = false; reload(); reloadDetail(); search(); activateStagedDownloads(); drainProcessingQueue() }
            for id in pendingRedactionMeetings.sorted() {
                do {
                    try await mutationCoordinator.withLease(meetingID: id, access: .exclusive) {
                        try await redactor.recoverPending(meetingID: id)
                    }
                    pendingRedactionMeetings.remove(id)
                } catch { self.error = "Passage deletion needs recovery for \(id): " + error.localizedDescription }
            }
        }
    }
    func renameSpeaker(_ speaker: Speaker, label: String) { do { try store?.renameSpeaker(id: speaker.id, label: label); reloadDetail() } catch { self.error = error.localizedDescription } }
    var availableSpeakerModels: [ModelDescriptor] { catalog?.models(for: .speakers) ?? [] }

    func groupSpeakersForReview(modelID: String) {
        if let id = selectedID, assetWorkBlocked(id) { return }
        guard let id = selectedID, !isRecording, !redactionBusy,
              !pendingRedactionMeetings.contains(id), processingID == nil,
              let processor, let catalog else {
            error = "Set up the local speaker-grouping model in Settings before reviewing speakers."
            return
        }
        guard let descriptor = catalog.model(modelID), descriptor.role == .speakers,
              health?.models[descriptor.id]?.ready == true else {
            error = "Set up the local speaker-grouping model in Settings before reviewing speakers."
            return
        }
        let version = activeTranscriptID
        processingID = id
        processingTask = Task { [self] in
            defer { processingID = nil; reloadDetail(); activateStagedDownloads(); drainProcessingQueue() }
            do {
                try await mutationCoordinator.withLease(meetingID: id, access: .exclusive) {
                    try await processor.groupSpeakers(meetingID: id, versionID: version,
                                                      model: ModelSelection(id: descriptor.id, revision: descriptor.revision))
                }
                status = "Speaker groups are ready to review."
            } catch { self.error = error.localizedDescription }
        }
    }

    func speakerPreviews(for run: SpeakerGroupingRun) async throws -> [String: [SpeakerPreview]] {
        guard let store else { return [:] }
        return try await Task.detached {
            let chunks = try store.chunks(meetingID: run.meetingID, track: run.track)
            let trackEvents = try store.captureTrackEvents(meetingID: run.meetingID)
                .reduce(into: [String: AudioTrack]()) { $0[$1.id] = $1.track }
            let gaps = try store.gaps(meetingID: run.meetingID).compactMap { gap -> Range<Double>? in
                guard trackEvents[gap.id] == nil || trackEvents[gap.id] == run.track,
                      let end = gap.endTime, end > gap.startTime else { return nil }
                return gap.startTime..<end
            }
            return SpeakerPreviewSelector.previews(for: run, coverage: chunks, redactions: gaps)
        }.value
    }

    func playSpeakerPreview(_ preview: SpeakerPreview, meetingID: String) {
        guard !assetWorkBlocked(meetingID) else { return }
        guard !isRecording, !redactionBusy, !pendingRedactionMeetings.contains(meetingID),
              selectedID == meetingID, let store else { return }
        do {
            let chunks = try store.chunks(meetingID: meetingID, track: preview.track)
            let selected = chunks.filter { $0.startTime < preview.end && $0.startTime + $0.duration > preview.start }
            guard !selected.isEmpty else { throw RuntimeError.service("This speaker sample is no longer available.") }
            stopPlayback()
            let player = try MeetingPlayer(directory: paths.meetingDirectory(meetingID), chunks: selected, audioAssets: store.audioAssets)
            player.rate = 1
            player.onError = { [weak self] message in self?.error = message }
            self.player = player
            playbackTrack = preview.track
            try player.play(range: preview.start..<preview.end)
            playing = true
            playbackTime = preview.start
        } catch { self.error = error.localizedDescription }
    }
    func saveNotes(_ draft: MeetingNotes) { do { var draft = draft; draft.id = UUID().uuidString; draft.createdAt = Date(); draft.isEdited = true; try store?.saveNotes(draft); reloadDetail() } catch { self.error = error.localizedDescription } }
    func renameMeeting(_ title: String, meetingID: String) { guard var meeting = try? store?.meeting(id: meetingID) else { return }; meeting.title = title; do { try store?.updateMeeting(meeting); reload() } catch { self.error = error.localizedDescription } }
    func search() {
        searchTask?.cancel()
        let query = searchQuery
        guard !query.isEmpty, let store else { searchResults = []; return }
        searchTask = Task {
            do {
                try await Task.sleep(nanoseconds: 200_000_000)
                let results = try await Task.detached { try store.search(query) }.value
                try Task.checkCancellation()
                if searchQuery == query { searchResults = results }
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }

    func exportSelected(meetingID: String? = nil) {
        guard let id = meetingID ?? selectedID else { return }
        if assetWorkBlocked(id) { return }
        guard let store, !redactionBusy,
              !pendingRedactionMeetings.contains(id) else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true; panel.prompt = "Export Here"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let accessed = destination.startAccessingSecurityScopedResource()
        let coordinator = mutationCoordinator
        exportTask = Task {
            defer { if accessed { destination.stopAccessingSecurityScopedResource() } }
            do {
                let output = try await coordinator.withLease(meetingID: id, access: .read) {
                    try await Task.detached { try MeetingExporter(store: store).export(meetingID: id, to: destination) }.value
                }
                NSWorkspace.shared.activateFileViewerSelecting([output]); status = "Export saved"
            } catch { self.error = error.localizedDescription }
        }
    }

    func importLibrary() {
        guard LibraryMutationPolicy.allowsLibraryImport(phase: libraryPhase, setupBusy: setupBusy, recording: isRecording, processing: processingID != nil, changingRecording: changingRecording, importingLibrary: importingLibrary, libraryImportPending: libraryImportPending, meetingCount: meetings.count) else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "Import Library"
        panel.message = "Quit the other Echo Voice installation, then choose its EchoVoice data folder. The source is preserved. Models remain installed separately. Restart this app after import."
        guard panel.runModal() == .OK, let source = panel.url else { return }
        let accessed = source.startAccessingSecurityScopedResource()
        importingLibrary = true
        let destination = paths
        Task {
            defer { importingLibrary = false; if accessed { source.stopAccessingSecurityScopedResource() } }
            do {
                try await Task.detached { try LibraryImport.stage(source: source, destination: destination) }.value
                libraryImportPending = true; status = "Library import prepared. Quit and reopen Echo Voice to finish."
            } catch { self.error = error.localizedDescription }
        }
    }

    func deleteSelected(meetingID: String? = nil) async {
        guard let id = meetingID ?? selectedID else { return }
        if assetWorkBlocked(id) { return }
        guard id != recordingID, !redactionBusy,
              !pendingRedactionMeetings.contains(id), let store else { return }
        deletingMeetings.insert(id)
        defer { deletingMeetings.remove(id); drainProcessingQueue() }
        if processingID == id { processingTask?.cancel(); await processor?.cancel(); await processingTask?.value }
        stopPlayback(); player = nil
        do {
            try await mutationCoordinator.withLease(meetingID: id, access: .exclusive) {
                try await Task.detached { try store.deleteMeeting(id: id) }.value
            }
            let wasSelected = selectedID == id
            reload(); if wasSelected { selectedID = meetings.first?.id }
        }
        catch {
            pendingMeetingDeletions = Set(store.deletionRecoveryIssues.map(\.meetingID))
            reload()
            if !meetings.contains(where: { $0.id == id }) { selectedID = meetings.first?.id }
            self.error = error.localizedDescription
        }
    }

    func play(at time: Double = 0, track: AudioTrack? = nil, meetingID: String? = nil) {
        guard meetingID == nil || meetingID == selectedID else { return }
        if let id = selectedID, assetWorkBlocked(id) { return }
        guard !isRecording, !redactionBusy, let id = selectedID,
              !pendingRedactionMeetings.contains(id), let store,
              selectedMeeting != nil else { return }
        do {
            let all = try store.chunks(meetingID: id)
            playbackTrack = track
            let chunks: [CapturedChunk]
            if let track {
                chunks = all.filter { $0.track == track }
            } else {
                chunks = all.filter { $0.track == .remote }
                    + (try store.microphoneTranscriptChunks(meetingID: id))
            }
            let speakerphoneChunks = try store.speakerphoneMicrophoneChunks(meetingID: id)
            let uncoveredMicrophone = AECCoverageAudit.uncovered(near: speakerphoneChunks, clean: all.filter { $0.track == .cleanMicrophone })
            if track == nil && !uncoveredMicrophone.isEmpty {
                status = "Conversation playback has missing cleaned microphone audio. Missing portions remain silent; raw microphone audio is available separately."
            }
            guard !chunks.isEmpty else { throw RuntimeError.service("This track has no saved audio. Choose another track.") }
            let player = try MeetingPlayer(directory: paths.meetingDirectory(id), chunks: chunks, audioAssets: store.audioAssets)
            player.rate = playbackRate; player.onError = { [weak self] message in self?.error = message }
            self.player?.stop(); self.player = player; try player.play(at: time); playing = true; playbackTime = time
        } catch { self.error = error.localizedDescription }
    }
    func stopPlayback() { player?.stop(); playing = false }
    func showEvidence(_ id: String) {
        if let meetingID = selectedID, let segment = try? store?.segment(meetingID: meetingID, versionID: activeTranscriptID, segmentID: id) {
            selectedTab = .transcript; play(at: segment.startTime, track: segment.track)
            Task { await transcriptList?.reveal(segmentID: id) }
            return
        }
        for version in transcriptVersions {
            if let meetingID = selectedID, let segment = try? store?.segment(meetingID: meetingID, versionID: version.id, segmentID: id) {
                status = "Playing evidence from an earlier transcript."; play(at: segment.startTime, track: segment.track); return
            }
        }
    }
}
