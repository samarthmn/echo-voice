import Foundation
import SwiftUI
import AppKit
import AVFoundation
import EchoCore
import EchoCapture
import EchoRuntime
import EchoIntelligence

extension AppModel {
    nonisolated static func openLibrary(_ paths: AppPaths) throws -> MeetingStore {
        try LibraryImport.activatePending(destination: paths)
        let store = try MeetingStore(paths: paths, deferAssetRecovery: true)
        _ = try store.recoverInterruptedMeetings()
        try store.recoverRunningJobs()
        return store
    }

    func finishOpeningLibrary(_ result: Result<MeetingStore, Error>) {
        if isShuttingDown { return }
        switch result {
        case .success(let opened):
            store = opened
            transcriptList = TranscriptListModel(store: opened)
            processor = MeetingProcessor(store: opened, paths: paths, service: service, intelligence: intelligence)
            redactor = RedactionCoordinator(store: opened, paths: paths)
            pendingRedactionMeetings = Set((try? opened.pendingRedactions().map(\.meetingID)) ?? [])
            pendingMeetingDeletions = Set(opened.deletionRecoveryIssues.map(\.meetingID))
            recoveringAssetMeetings = Set((try? opened.meetings().map(\.id)) ?? [])
            damagedAssetMeetings = []
            libraryRecovery = nil
            libraryPhase = .ready
            status = "Ready when you are"
            reload()
            selectedID = meetings.first?.id
            reloadDetail()
            Task.detached(priority: .utility) { [weak self, opened] in
                do { try opened.retireVisualContext() }
                catch { await MainActor.run { [weak self] in self?.error = "Some retired visual files still need cleanup: " + error.localizedDescription } }
            }
            Task { [weak self, opened] in
                guard let self else { return }
                do {
                    try await self.recoverMeetingDeletionIntents(store: opened)
                    let issues = opened.deletionRecoveryIssues
                    if let issue = issues.first {
                        self.error = "A meeting deletion needs recovery: " + issue.message + ". Other meetings are available."
                    }
                } catch { self.error = "Could not recover meeting deletions: " + error.localizedDescription }
                for id in self.pendingRedactionMeetings.sorted() {
                    do {
                        try await self.mutationCoordinator.withLease(meetingID: id, access: .exclusive) {
                            try await self.redactor?.recoverPending(meetingID: id)
                        }
                        self.pendingRedactionMeetings.remove(id)
                    } catch {
                        self.error = "A passage deletion needs recovery for \(id): " + error.localizedDescription
                    }
                }
                self.reload(); self.reloadDetail()
                for id in self.recoveringAssetMeetings.sorted() {
                    guard !self.pendingMeetingDeletions.contains(id), (try? opened.meeting(id: id)) != nil else {
                        self.recoveringAssetMeetings.remove(id)
                        continue
                    }
                    do {
                        try await self.mutationCoordinator.withLease(meetingID: id, access: .exclusive) {
                            try await Task.detached(priority: .utility) { try opened.recoverMeetingAsset(meetingID: id) }.value
                        }
                    } catch {
                        self.damagedAssetMeetings.insert(id)
                        self.error = "Audio repair needed for \(id): \(error.localizedDescription). Other meetings are available."
                        self.status = "Some meetings need audio repair"
                    }
                    self.recoveringAssetMeetings.remove(id)
                    self.reload(); self.reloadDetail()
                }
                self.drainProcessingQueue()
                self.scheduleCompaction(for: self.meetings.filter {
                    $0.state == .ready && !self.damagedAssetMeetings.contains($0.id)
                        && !self.pendingMeetingDeletions.contains($0.id)
                }.map(\.id))
            }
        case .failure(let error):
            store = nil
            processor = nil
            libraryRecovery = LibraryRecovery.message(root: paths.root, reason: error.localizedDescription)
            libraryPhase = .unavailable
            status = "Library needs attention"
        }
        refreshSources()
        Task {
            await refreshHealth()
            restoreStagedDownloads()
            drainProcessingQueue()
            if defaultNotesSelection()?.provider == .ollama || queuedProcessing.contains(where: {
                (try? store?.configuration(meetingID: $0.meetingID))?.notes?.provider == .ollama
            }) { await refreshOllamaModels() }
            if libraryPhase == .ready && !readiness.requiredComplete && !UserDefaults.standard.bool(forKey: Self.onboardingDismissedKey) { presentSetupGuide() }
        }
    }

    func reload() { do { meetings = try store?.meetings() ?? [] } catch { self.error = error.localizedDescription } }

    func assetWorkBlocked(_ meetingID: String) -> Bool {
        if deletingMeetings.contains(meetingID) {
            error = "This meeting is being deleted."
            return true
        }
        if pendingMeetingDeletions.contains(meetingID) {
            error = "A deletion needs recovery for this meeting. Use Retry deletion recovery to continue."
            return true
        }
        if recoveringAssetMeetings.contains(meetingID) {
            error = "Audio recovery is still checking this meeting. Try again shortly."
            return true
        }
        if damagedAssetMeetings.contains(meetingID) {
            error = "This meeting has an audio asset that needs repair before recording, processing, playback, export, or deletion."
            return true
        }
        return false
    }

    func retryAssetRecovery(meetingID: String) {
        guard let store, damagedAssetMeetings.contains(meetingID),
              !recoveringAssetMeetings.contains(meetingID) else { return }
        damagedAssetMeetings.remove(meetingID)
        recoveringAssetMeetings.insert(meetingID)
        Task {
            do {
                try await mutationCoordinator.withLease(meetingID: meetingID, access: .exclusive) {
                    try await Task.detached(priority: .utility) { try store.recoverMeetingAsset(meetingID: meetingID) }.value
                }
                status = "Audio recovery completed for this meeting"
            } catch {
                damagedAssetMeetings.insert(meetingID)
                self.error = "Audio repair still needed for \(meetingID): \(error.localizedDescription)"
            }
            recoveringAssetMeetings.remove(meetingID)
            reload(); reloadDetail(); activateStagedDownloads(); drainProcessingQueue()
        }
    }
    func retryMeetingDeletions() {
        guard let store, deletingMeetings.isEmpty else { return }
        Task {
            do {
                try await recoverMeetingDeletionIntents(store: store)
                let issues = store.deletionRecoveryIssues
                if let issue = issues.first { error = "Deletion recovery still needs attention: " + issue.message }
                else { status = "Meeting deletions recovered" }
            } catch { self.error = error.localizedDescription }
            reload(); reloadDetail()
        }
    }

    func recoverMeetingDeletionIntents(store: MeetingStore) async throws {
        for id in pendingMeetingDeletions.sorted() {
            try await mutationCoordinator.withLease(meetingID: id, access: .exclusive) {
                _ = try await Task.detached(priority: .utility) { try store.recoverDeletionTransactions(meetingID: id) }.value
            }
        }
        pendingMeetingDeletions = Set(store.deletionRecoveryIssues.map(\.meetingID))
    }

    func reloadDetail() {
        detailGeneration += 1
        guard let id = selectedID, let store else {
            notes = []; jobStatus = nil; gaps = []; speakers = []; selectedConfiguration = nil
            groupingRuns = []; availableTracks = []; displayedTranscriptKey = nil
            return
        }
        guard detailTask == nil else { pendingDetailRefresh = true; return }
        let request = detailGeneration
        detailTask = Task { [weak self, store] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try MeetingDetailSnapshot(store: store, meetingID: id) }
            }.value
            guard let self else { return }
            self.detailTask = nil
            if self.detailGeneration == request && self.selectedID == id {
                switch result {
                case .success(let snapshot): self.applyDetail(snapshot, meetingID: id)
                case .failure(let error): self.error = error.localizedDescription
                }
            }
            if self.pendingDetailRefresh {
                self.pendingDetailRefresh = false
                self.reloadDetail()
            }
        }
    }

    func applyDetail(_ snapshot: MeetingDetailSnapshot, meetingID: String) {
        workspace.resolveInitialTab(hasNotes: !snapshot.notes.isEmpty, recording: recordingID == meetingID || selectedMeeting?.state == .recording)
        if notes != snapshot.notes { notes = snapshot.notes }
        if activeTranscriptID != snapshot.activeTranscriptID { activeTranscriptID = snapshot.activeTranscriptID }
        let key = meetingID + "/" + snapshot.activeTranscriptID + "/" + String(selectedMeeting?.transcriptRevision ?? 0)
        if displayedTranscriptKey != key, let transcriptList {
            displayedTranscriptKey = key
            Task { await transcriptList.load(meetingID: meetingID, versionID: snapshot.activeTranscriptID) }
        }
        if annotations != snapshot.annotations { annotations = snapshot.annotations }
        if transcriptVersions != snapshot.transcriptVersions { transcriptVersions = snapshot.transcriptVersions }
        if selectedConfiguration != snapshot.configuration { selectedConfiguration = snapshot.configuration }
        if groupingRuns != snapshot.groupingRuns {
            groupingRuns = snapshot.groupingRuns
            speakerTurnIndices = Dictionary(uniqueKeysWithValues: snapshot.groupingRuns.map { ($0.id, SpeakerTurnIndex(run: $0)) })
        }
        if availableTracks != snapshot.availableTracks { availableTracks = snapshot.availableTracks }
        if speakers != snapshot.speakers { speakers = snapshot.speakers }
        if jobStatus != snapshot.jobStatus { jobStatus = snapshot.jobStatus }
        if gaps != snapshot.gaps { gaps = snapshot.gaps }
    }

}

struct MeetingDetailSnapshot: Sendable {
    let notes: [MeetingNotes]
    let activeTranscriptID: String
    let annotations: [TranscriptAnnotation]
    let transcriptVersions: [TranscriptVersion]
    let configuration: ProcessingConfiguration?
    let groupingRuns: [SpeakerGroupingRun]
    let availableTracks: Set<AudioTrack>
    let speakers: [Speaker]
    let jobStatus: MeetingStore.JobStatusSummary
    let gaps: [CaptureGap]

    init(store: MeetingStore, meetingID: String) throws {
        notes = try store.notes(meetingID: meetingID)
        activeTranscriptID = try store.activeTranscriptVersion(meetingID: meetingID)
        annotations = try store.annotations(meetingID: meetingID)
        transcriptVersions = try store.transcriptVersions(meetingID: meetingID)
        configuration = try store.configuration(meetingID: meetingID)
        groupingRuns = try store.speakerGroupingRuns(meetingID: meetingID)
        availableTracks = try store.availableTracks(meetingID: meetingID)
        speakers = try store.speakers(meetingID: meetingID)
        jobStatus = try store.jobStatusSummary(meetingID: meetingID)
        gaps = try store.gaps(meetingID: meetingID)
    }
}
