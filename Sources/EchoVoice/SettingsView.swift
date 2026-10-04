import SwiftUI
import EchoCore

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, models, vocabulary, audio, storage, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "General"
        case .models: "Models"
        case .vocabulary: "Vocabulary"
        case .audio: "Audio & Permissions"
        case .storage: "Storage"
        case .about: "About"
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .models: "cpu"
        case .vocabulary: "character.book.closed"
        case .audio: "waveform"
        case .storage: "internaldrive"
        case .about: "info.circle"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 0) {
            List(selection: $model.settingsPage) {
                ForEach(SettingsPage.allCases) { page in Label(page.title, systemImage: page.symbol).tag(page) }
            }.listStyle(.sidebar).frame(width: 190)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.l) {
                        if let recovery = model.libraryRecovery { Banner(message: recovery, tone: .problem) }
                        Text(model.settingsPage.title).font(Theme.Font.pageTitle)
                        switch model.settingsPage {
                        case .general: GeneralSettingsView()
                        case .models: ModelSettingsView()
                        case .vocabulary: VocabularySettingsView()
                        case .audio: AudioSettingsView()
                        case .storage: StorageSettingsView()
                        case .about: AboutSettingsView()
                        }
                    }.frame(maxWidth: 720, alignment: .leading).padding(Theme.Space.xl)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .onChange(of: model.settingsModelRole) { _, role in withAnimation { proxy.scrollTo(role, anchor: .top) } }
                .onAppear { proxy.scrollTo(model.settingsModelRole, anchor: .top) }
            }
        }
        .frame(minWidth: 780, minHeight: 580)
        .tint(Theme.accent)
        .onAppear { model.refreshPermissions(); Task { await model.refreshHealth() } }
        .alert("Settings need attention", isPresented: Binding(get: { model.setupError != nil }, set: { if !$0 { model.setupError = nil } })) {
            Button("OK") { model.setupError = nil }
        } message: { Text(model.setupError ?? "") }
    }
}

private struct GeneralSettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    private let shortcuts = [("⌘N", "New meeting"), ("⌘F", "Search transcripts"), ("⇧⌘P", "Pause or resume recording"), ("⌘.", "Stop recording"), ("Space", "Play or pause replay"), ("⌘,", "Settings")]
    var body: some View {
        let overall = model.readiness.overall
        SectionCard("Setup status", subtitle: "What Echo Voice needs before and after your first meeting.", systemImage: "checklist", trailing: AnyView(StatusBadge(text: overall.title, tone: overall.tone))) {
            SetupChecklistView()
            HStack {
                Spacer()
                Button("Open Setup Guide") { openWindow(id: "main"); model.presentSetupGuide() }
                    .disabled(!model.canPresentSetupGuide)
            }
        }
        SectionCard("Privacy", systemImage: "lock.shield") {
            Text("Meeting content stays on your Mac. Downloads happen only when you choose to install or repair a model.").fixedSize(horizontal: false, vertical: true)
        }
        SectionCard("Keyboard shortcuts", systemImage: "keyboard") {
            Grid(alignment: .leading, horizontalSpacing: Theme.Space.xl, verticalSpacing: Theme.Space.s) {
                ForEach(shortcuts, id: \.0) { key, action in
                    GridRow {
                        Text(key).font(.callout.monospaced()).padding(.horizontal, 6).padding(.vertical, 2).background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: Theme.Radius.s))
                        Text(action).font(.callout)
                    }
                }
            }
        }
    }
}

private struct AudioSettingsView: View {
    var body: some View {
        SectionCard("Permissions", subtitle: "Status updates when you return from System Settings.", systemImage: "hand.raised") {
            PermissionRow(kind: .microphone)
            Divider()
            PermissionRow(kind: .meetingAudio)
        }
        SectionCard("Recording inputs", systemImage: "mic") {
            Text("Choose your microphone and meeting application before each recording. Echo Voice records only the application you select.").fixedSize(horizontal: false, vertical: true)
            Text("With Mac speakers, speakerphone mode preserves both raw recordings and transcribes a separate cleaned microphone track. With headphones, leave it off.").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct StorageSettingsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        SectionCard("Local data", subtitle: "Recordings, transcripts, and notes stay on this Mac until you delete their meeting. Independent exports are retained.", systemImage: "internaldrive") {
            Text(model.paths.root.path).font(.caption.monospaced()).textSelection(.enabled).foregroundStyle(.secondary)
            Button("Show in Finder") { NSWorkspace.shared.open(model.paths.root) }
        }
        SectionCard("Import a library", subtitle: "Copies a library into an empty installation. The source is preserved; quit the other installation first.", systemImage: "square.and.arrow.down") {
            HStack {
                Button(model.importingLibrary ? "Validating library…" : "Import Echo Voice Library…") { model.importLibrary() }
                    .disabled(!model.meetings.isEmpty || model.importingLibrary || model.libraryImportPending || !model.modelChangesAllowed)
                if !model.meetings.isEmpty { Text("Available only while this library is empty.").font(.caption).foregroundStyle(.secondary) }
            }
            if model.libraryImportPending { Banner(message: "Import ready. Quit and reopen Echo Voice to finish.") }
        }
    }
}

private struct AboutSettingsView: View {
    var body: some View {
        SectionCard {
            HStack(spacing: Theme.Space.l) {
                BrandMark(size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Echo Voice").font(.title2.weight(.semibold))
                    Text("\(ReleaseConfiguration.version) · \(ReleaseConfiguration.channel.rawValue)").font(.callout).foregroundStyle(.secondary)
                }
            }
            Text("A private meeting workspace for your Mac. Speech recognition, notes, and speaker grouping run locally.").fixedSize(horizontal: false, vertical: true)
            if ReleaseConfiguration.channel != .appStore { Link("Check for updates", destination: ReleaseConfiguration.releasesURL) }
        }
    }
}

private struct ModelSettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var selected: [ModelRole: String] = [:]
    @State private var removing: ModelDescriptor?
    @State private var notesProvider = ModelProvider.native
    @State private var selectedOllama = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            if model.catalog == nil {
                Banner(message: "The model catalog could not be read. Meeting data was left in place. Reinstall Echo Voice if this continues.", tone: .problem)
            }
            Text("Choose which local model handles each task. Selecting a card only inspects it; your default changes when you choose Use as Default or download a replacement for a default that isn't ready.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            runtimeCard
            if model.activeDownload != nil || !model.queuedDownloads.isEmpty {
                SectionCard("Downloads", systemImage: "arrow.down.circle") { DownloadQueueView() }
            }
            roleCard(.speech).id(ModelRole.speech)
            notesCard.id(ModelRole.notes)
            roleCard(.speakers).id(ModelRole.speakers)
        }
        .confirmationDialog("Remove this model?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            if let entry = removing { Button("Remove " + entry.displayName, role: .destructive) { model.removeModel(entry.id); removing = nil } }
        } message: { Text("Saved transcripts and notes remain. If this is your default, that task becomes unconfigured until you choose another model. Pending jobs will require their original model to be downloaded again.") }
        .onAppear {
            let current = model.defaultNotesSelection()
            notesProvider = current?.provider ?? .native
            if current?.provider == .ollama { selectedOllama = current?.id ?? "" }
            for role in ModelRole.allCases where selected[role] == nil {
                let fallback = model.catalog?.models(for: role).first?.id ?? ""
                let roleDefault = model.defaultModel(role)
                selected[role] = role == .notes && notesProvider == .ollama ? (model.catalog?.model("notes")?.id ?? fallback) : (roleDefault.isEmpty ? fallback : roleDefault)
            }
        }
    }

    private var runtimeCard: some View {
        SectionCard("Local runtime", systemImage: "desktopcomputer") {
            if let item = model.readiness.item(.runtime) {
                StatusRow(item: item) {
                    Button(model.runtimeBundled ? "Check Runtime" : model.health == nil ? "Install Runtime" : "Repair Runtime") { model.installRuntime() }
                        .disabled(!model.modelChangesAllowed)
                }
            }
            if model.setupBusy && model.activeDownload == nil {
                HStack { ProgressView().controlSize(.small); Text(model.setupProgress).font(.caption).foregroundStyle(.secondary); Spacer(); Button("Cancel") { model.cancelSetup() } }
            } else if model.activeDownload == nil {
                Text(model.setupProgress).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func selection(_ role: ModelRole) -> Binding<String> {
        Binding(get: { selected[role] ?? model.defaultModel(role) }, set: { selected[role] = $0 })
    }

    private func roleHeader(_ role: ModelRole) -> AnyView {
        AnyView(HStack(spacing: Theme.Space.s) {
            StatusBadge(text: "Default: " + defaultLabel(role), tone: defaultTone(role))
            if role != .speech {
                Button("Turn Off") { model.setDefaultModel("", role: role) }.controlSize(.small)
                    .disabled(role == .notes ? model.defaultNotesSelection() == nil : model.defaultModel(role).isEmpty)
            }
        })
    }

    private func roleCard(_ role: ModelRole) -> some View {
        SectionCard(role.title, subtitle: role.purpose, systemImage: role.symbol, trailing: roleHeader(role)) {
            ModelOptionCards(role: role, selection: selection(role))
            modelDetails(selection(role).wrappedValue)
        }
    }

    @ViewBuilder private func modelDetails(_ id: String) -> some View {
        if let entry = model.catalog?.model(id) {
            ModelActions(entry: entry, showsMaintenance: true, onRemove: { removing = entry }).id(entry.id)
            DisclosureGroup("Model details") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Source: " + entry.repo).textSelection(.enabled)
                    Text("Revision: " + entry.revision).font(.caption.monospaced()).textSelection(.enabled)
                    Text("License: " + entry.license)
                }.font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
            }.font(.caption)
        }
    }

    private var notesCard: some View {
        SectionCard(ModelRole.notes.title, subtitle: ModelRole.notes.purpose, systemImage: ModelRole.notes.symbol, trailing: roleHeader(.notes)) {
            Picker("Run using", selection: $notesProvider) { Text("Native").tag(ModelProvider.native); Text("Ollama").tag(ModelProvider.ollama) }.pickerStyle(.segmented).frame(maxWidth: 280)
            if notesProvider == .native {
                ModelOptionCards(role: .notes, selection: selection(.notes))
                modelDetails(selection(.notes).wrappedValue)
            } else {
                HStack {
                    Label(model.ollamaStatus, systemImage: !model.ollamaChecked ? "circle.dashed" : model.ollamaModels.isEmpty ? "exclamationmark.circle" : "checkmark.circle")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(!model.ollamaChecked ? Color.secondary : model.ollamaModels.isEmpty ? .orange : .green)
                    Spacer()
                    Button(model.refreshingOllama ? "Refreshing…" : "Refresh") { Task { await model.refreshOllamaModels() } }.disabled(model.refreshingOllama)
                }
                if model.ollamaModels.isEmpty && model.ollamaChecked && !model.ollamaStatus.contains("Could not connect") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No models found in Ollama. Pull a model in Terminal:").font(.caption).foregroundStyle(.secondary)
                        Text("ollama run llama3.2").font(.caption.monospaced()).textSelection(.enabled).padding(4).background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                Picker("Ollama model", selection: $selectedOllama) {
                    Text("Choose an installed model").tag("")
                    ForEach(model.ollamaModels) { Text($0.name).tag($0.name) }
                }
                if let entry = model.ollamaModels.first(where: { $0.name == selectedOllama }) {
                    HStack { Label("Managed by Ollama", systemImage: "shippingbox"); Spacer(); Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)).monospacedDigit() }.font(.caption)
                    Text("Digest: " + entry.digest).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    let selection = ModelSelection(id: entry.name, revision: entry.digest, provider: .ollama)
                    if model.defaultNotesSelection() == selection { Label("Default for new meetings", systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green) }
                    else { Button("Use as Default") { model.setDefaultNotes(selection) }.buttonStyle(.borderedProminent) }
                } else if !selectedOllama.isEmpty {
                    Label("The selected Ollama model is no longer available.", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
                Text("Echo Voice connects only to Ollama on this Mac and neither installs nor removes Ollama models.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .task { if notesProvider == .ollama { await model.refreshOllamaModels() } }
        .onChange(of: notesProvider) { _, provider in
            if provider == .ollama { Task { await model.refreshOllamaModels() } }
            else if model.catalog?.model(selected[.notes] ?? "") == nil { selected[.notes] = model.catalog?.model("notes")?.id ?? "" }
        }
    }

    private func defaultLabel(_ role: ModelRole) -> String {
        if role == .notes {
            guard let selection = model.defaultNotesSelection() else { return "Off" }
            return selection.provider == .ollama ? "Ollama · " + selection.id : (model.catalog?.model(selection.id)?.displayName ?? selection.id)
        }
        let id = model.defaultModel(role)
        if id.isEmpty { return "Off" }
        return model.catalog?.model(id)?.displayName ?? "Not configured"
    }

    private func defaultTone(_ role: ModelRole) -> StatusTone {
        let item = model.readiness.item(role == .speech ? .speech : role == .notes ? .notes : .speakers)
        return item?.state.tone ?? .neutral
    }
}
