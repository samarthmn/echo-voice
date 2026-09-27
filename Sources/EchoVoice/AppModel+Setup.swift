import Foundation
import EchoCore
import EchoRuntime

struct ModelDownload: Identifiable, Equatable {
    let id: String
    let name: String
    let role: ModelRole
    let makeDefault: Bool
    fileprivate let token: String?
    var tally: DownloadTally
    var message = "Waiting to start…"
    var fraction: Double? { tally.totalBytes > 0 && tally.completedBytes > 0 ? tally.fraction : nil }
}

extension AppModel {
    var runtimeBundled: Bool { RuntimeLayout(paths: paths).bundled }

    var readiness: SetupReadiness {
        var inputs = SetupReadiness.Inputs()
        inputs.libraryProblem = libraryRecovery
        inputs.libraryReady = libraryPhase == .ready
        inputs.runtimeChecked = runtimeChecked
        inputs.runtimeAvailable = health != nil
        inputs.runtimeBundled = runtimeBundled
        let speech = defaultModel(.speech)
        inputs.speechModelID = speech
        inputs.speechModelName = catalog?.model(speech)?.displayName
        inputs.speechReady = isModelReady(speech)
        if let notes = defaultNotesSelection() {
            if notes.provider == .ollama {
                let available = !ollamaChecked || ollamaModels.contains { $0.name == notes.id && $0.digest == notes.revision }
                inputs.notes = available ? .ready("Ollama · " + notes.id) : .unavailable("Ollama · " + notes.id)
            } else {
                inputs.notes = optionalModel(notes.id)
            }
        }
        inputs.speakers = defaultModel(.speakers).isEmpty ? .off : optionalModel(defaultModel(.speakers))
        inputs.microphone = microphonePermission
        inputs.meetingAudio = meetingAudioPermission
        if let activeDownload { inputs.download = .init(modelID: activeDownload.id, name: activeDownload.name, fraction: activeDownload.fraction) }
        inputs.queuedDownloads = queuedDownloads.count
        return SetupReadiness(inputs)
    }

    private func optionalModel(_ id: String) -> SetupReadiness.OptionalModel {
        let name = catalog?.model(id)?.displayName ?? id
        return isModelReady(id) ? .ready(name) : .needsDownload(id: id, name: name)
    }

    func isModelReady(_ id: String) -> Bool { health?.models[id]?.ready == true }
    func isDownloading(_ id: String) -> Bool { activeDownload?.id == id || queuedDownloads.contains { $0.id == id } }
    func download(for id: String) -> ModelDownload? { activeDownload?.id == id ? activeDownload : queuedDownloads.first { $0.id == id } }

    /// Recording waits for setup so installs never replace a runtime that live processing is using.
    var newMeetingBlockedReason: String? {
        if libraryRecovery != nil { return "The library needs attention before recording." }
        if store == nil { return "Your library is still opening." }
        if isRecording { return "A meeting is already recording." }
        if testingInputs || changingRecording { return "Audio devices are busy. Try again in a moment." }
        if importingLibrary || libraryImportPending { return "Finish the library import before recording." }
        if setupBusy {
            if let activeDownload { return "\(activeDownload.name) is downloading. Recording is available when it finishes, or cancel the download." }
            return "Local setup is running. Recording is available when it finishes."
        }
        return nil
    }

    func startBlockedReason(consent: Bool) -> String? {
        if let reason = newMeetingBlockedReason { return reason }
        if !consent { return "Confirm that you have consent to record this meeting." }
        return nil
    }

    func installRuntime() {
        guard modelChangesAllowed else { return }
        setupBusy = true; setupProgress = "Preparing local setup…"
        setupTask = Task { [self] in
            defer { setupBusy = false; startNextDownload() }
            do {
                await service.stop()
                guard let resources = Bundle.main.resourceURL else { throw RuntimeError.setupNeeded }
                try await installer.installRuntime(resources: resources) { [weak self] progress in Task { @MainActor in self?.setupProgress = progress.message } }
                setupProgress = runtimeBundled ? "The runtime is included and ready. Choose a model to download." : "Runtime installed. Download a speech model next."
                await refreshHealth()
            } catch is CancellationError {
                await Task { await self.refreshHealth() }.value
                setupProgress = "Setup paused. You can retry when ready."
            } catch { self.error = error.localizedDescription; setupProgress = error.localizedDescription; await refreshHealth() }
        }
    }

    /// Downloads run one at a time; the runtime is stopped for each install.
    func enqueueDownload(_ id: String, token: String? = nil, makeDefault: Bool = false) {
        guard let catalog, let descriptor = catalog.model(id), !isDownloading(id) else { return }
        queuedDownloads.append(ModelDownload(id: id, name: descriptor.displayName, role: descriptor.role, makeDefault: makeDefault, token: token, tally: DownloadTally(catalog: catalog, modelID: id)))
        startNextDownload()
    }

    func installModels(_ id: String, token: String? = nil) { enqueueDownload(id, token: token) }

    func removeQueuedDownload(_ id: String) { queuedDownloads.removeAll { $0.id == id } }

    /// Cancels the active download and everything queued behind it. Verified files are retained.
    func cancelSetup() {
        queuedDownloads = []
        setupTask?.cancel()
    }

    func cancelDownload(_ id: String) {
        if activeDownload?.id == id { setupTask?.cancel() } else { removeQueuedDownload(id) }
    }

    func startNextDownload() {
        guard activeDownload == nil, !queuedDownloads.isEmpty, modelChangesAllowed else { return }
        let next = queuedDownloads.removeFirst()
        activeDownload = next
        setupBusy = true
        setupProgress = "Preparing to download \(next.name)…"
        setupTask = Task { [self] in
            // cancelSetup() and shutdown() empty the queue first, so this only
            // continues after a single download was cancelled or finished.
            defer {
                activeDownload = nil; setupBusy = false
                startNextDownload()
            }
            do {
                await service.stop()
                try await installer.installModels(next.id, token: next.token) { [weak self] progress in
                    Task { @MainActor in self?.apply(progress, to: next.id) }
                }
                await refreshHealth()
                if next.makeDefault && isModelReady(next.id) { setDefaultModel(next.id, role: next.role) }
                setupProgress = "\(next.name) is downloaded and verified. Processing can run offline."
            } catch is CancellationError {
                await Task { await self.refreshHealth() }.value
                setupProgress = "Download paused. Verified files are kept for when you retry."
            } catch {
                self.error = "\(next.name): " + error.localizedDescription
                setupProgress = error.localizedDescription
                await refreshHealth()
            }
        }
    }

    private func apply(_ progress: SetupProgress, to id: String) {
        guard var download = activeDownload, download.id == id else { return }
        if let asset = progress.model {
            if progress.stage == "model" && progress.status == "ready" { download.tally.markComplete(asset: asset) }
            else if let completed = progress.completedBytes { download.tally.record(asset: asset, completedBytes: completed) }
        }
        switch progress.stage {
        case "download": download.message = "Downloading…"
        case "verify": download.message = "Verifying…"
        default: download.message = progress.message
        }
        activeDownload = download
        setupProgress = download.message
    }

    /// The main window presents one sheet at a time; a second request would stay pending and appear later.
    var canPresentSetupGuide: Bool { !showNewMeeting && !isRecording }
    func presentSetupGuide() {
        guard canPresentSetupGuide else { return }
        showOnboarding = true
    }

    func dismissOnboarding() {
        UserDefaults.standard.set(true, forKey: Self.onboardingDismissedKey)
        showOnboarding = false
    }
}
