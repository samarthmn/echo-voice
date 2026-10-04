import Foundation
import EchoCore
import EchoRuntime

extension AppModel {
    private static let bundledCatalog = try? ModelCatalog(url: ModelCatalog.bundledURL)
    var catalog: ModelCatalog? { Self.bundledCatalog }
    var modelChangesAllowed: Bool {
        !isShuttingDown && !redactionBusy && inferenceHandoff == nil && activeDownload == nil && LibraryMutationPolicy.allowsModelChanges(phase: libraryPhase, setupBusy: setupBusy, recording: isRecording, processing: processingID != nil, changingRecording: changingRecording, importingLibrary: importingLibrary, libraryImportPending: libraryImportPending)
    }
    func defaultModel(_ role: ModelRole) -> String {
        if role == .notes { return defaultNotesSelection()?.id ?? "" }
        if let saved = try? store?.preference("default.\(role.rawValue)", as: String.self) { return saved }
        switch role {
        case .speech: return UserDefaults.standard.string(forKey: "speechRecognitionModel").map { $0 == "parakeet" ? "parakeet" : "asr" } ?? "parakeet"
        case .notes: return "notes"
        case .speakers: return "diarization"
        }
    }
    func defaultNotesSelection() -> ModelSelection? {
        if let selection = try? store?.preference("default.notes.selection", as: ModelSelection.self) { return selection }
        if let legacy = try? store?.preference("default.notes", as: String.self) {
            guard !legacy.isEmpty else { return nil }
            if let descriptor = catalog?.model(legacy) { return ModelSelection(id: descriptor.id, revision: descriptor.revision) }
        }
        guard let descriptor = catalog?.model("notes") else { return nil }
        return ModelSelection(id: descriptor.id, revision: descriptor.revision)
    }
    func setDefaultNotes(_ selection: ModelSelection?) {
        do {
            if let selection {
                if selection.provider == .native {
                    guard catalog?.model(selection.id)?.role == .notes, health?.models[selection.id]?.ready == true else { throw RuntimeError.setupNeeded }
                } else {
                    guard ollamaModels.contains(where: { $0.name == selection.id && $0.digest == selection.revision }) else { throw RuntimeError.service("Refresh Ollama and choose an installed local model.") }
                }
                try store?.setPreference("default.notes.selection", value: selection)
                try store?.setPreference("default.notes", value: selection.provider == .native ? selection.id : "")
            } else {
                try store?.setPreference("default.notes.selection", value: Optional<ModelSelection>.none)
                try store?.setPreference("default.notes", value: "")
            }
            objectWillChange.send()
        } catch { self.setupError = error.localizedDescription }
    }
    func setDefaultModel(_ id: String, role: ModelRole) {
        if role == .notes {
            if id.isEmpty { setDefaultNotes(nil) }
            else if let descriptor = catalog?.model(id) { setDefaultNotes(.init(id: descriptor.id, revision: descriptor.revision)) }
            return
        }
        guard id.isEmpty || (catalog?.model(id)?.role == role && health?.models[id]?.ready == true) else { error = "Download and verify this model before making it the default."; return }
        do {
            try store?.setPreference("default.\(role.rawValue)", value: id)
            if role == .speech { UserDefaults.standard.set(id == "asr" ? "whisper" : id, forKey: "speechRecognitionModel") }
            objectWillChange.send()
        } catch { self.setupError = error.localizedDescription }
    }
    func processingConfiguration(speech: SpeechRecognitionModel, includeVocabulary: Bool = true,
                                 speakerModelID: String? = nil) throws -> ProcessingConfiguration {
        guard let catalog, let descriptor = catalog.model(speech == .parakeet ? "parakeet" : "asr") else { throw RuntimeError.setupNeeded }
        func selection(_ id: String) -> ModelSelection? { catalog.model(id).map { ModelSelection(id: $0.id, revision: $0.revision) } }
        return ProcessingConfiguration(speech: .init(id: descriptor.id, revision: descriptor.revision), notes: defaultNotesSelection(), speakers: selection(speakerModelID ?? defaultModel(.speakers)), vocabulary: includeVocabulary ? (try store?.vocabulary() ?? []).filter(\.enabled) : [], fuzzyVocabulary: speech == .parakeet && includeVocabulary && UserDefaults.standard.bool(forKey: "fuzzyVocabulary"))
    }
    func refreshOllamaModels() async {
        guard !refreshingOllama else { return }
        refreshingOllama = true; defer { refreshingOllama = false; ollamaChecked = true; drainProcessingQueue() }
        do {
            ollamaModels = try await ollamaNotes.models()
            ollamaStatus = ollamaModels.isEmpty ? "Ollama is running, but no compatible local text models are installed." : "\(ollamaModels.count) compatible local model\(ollamaModels.count == 1 ? "" : "s") found."
        } catch {
            ollamaModels = []; ollamaStatus = error.localizedDescription
        }
    }
    func removeModel(_ id: String) {
        guard modelChangesAllowed, let descriptor = catalog?.model(id) else { return }
        setupBusy = true
        setupTask = Task {
            defer { setupBusy = false; startNextDownload(); drainProcessingQueue() }
            do {
                await service.stop(); await intelligence.releaseCache()
                // The confirmation describes the now-unconfigured default. Keep jobs pinned.
                if defaultModel(descriptor.role) == id { setDefaultModel("", role: descriptor.role) }
                try await installer.removeModel(id)
                setupProgress = "Model removed. Saved transcripts and notes are retained. Pending work keeps its original model selection."
                await refreshHealth()
            } catch { self.setupError = error.localizedDescription; await refreshHealth() }
        }
    }
}
