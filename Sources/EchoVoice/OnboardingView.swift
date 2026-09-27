import SwiftUI
import EchoCore

struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @State private var step = 0
    @State private var speechChoice = ""
    @State private var notesChoice = ""
    @State private var speakersChoice = ""
    @State private var notesChoiceType = 0 // 0: Native, 1: Ollama, 2: Off
    @State private var selectedOllama = ""
    private let steps = ["Welcome", "Runtime", "Speech", "Notes & Ollama", "Permissions", "Ready"]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                StepIndicator(steps: steps, current: step) { step = $0 }
                Spacer()
                Button("Skip Setup") { model.dismissOnboarding() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("You can reopen the Setup Guide anytime from the Help menu or status indicator.")
            }
            .padding(.horizontal, Theme.Space.xl).padding(.vertical, Theme.Space.l)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) { page }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Space.xxl)
            }
            Divider()
            HStack {
                if step > 0 { Button("Back") { step -= 1 }.keyboardShortcut(.cancelAction) }
                Spacer()
                if model.activeDownload != nil, step < steps.count - 1 {
                    Label("Downloads continue in the background", systemImage: "arrow.down.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                bottomNavigationButton
            }
            .padding(.horizontal, Theme.Space.xl).padding(.vertical, Theme.Space.l)
        }
        .frame(width: 760, height: 650)
        .alert("Echo Voice", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .onAppear {
            speechChoice = model.defaultModel(.speech)
            let notesSelection = model.defaultNotesSelection()
            if notesSelection?.provider == .ollama {
                notesChoiceType = 1
                selectedOllama = notesSelection?.id ?? ""
            } else if notesSelection?.provider == .native {
                notesChoiceType = 0
                notesChoice = notesSelection?.id ?? model.defaultModel(.notes)
            } else {
                notesChoiceType = model.defaultModel(.notes).isEmpty ? 2 : 0
                notesChoice = model.defaultModel(.notes)
            }
            speakersChoice = model.defaultModel(.speakers)
            model.refreshPermissions()
            if !model.runtimeChecked { Task { await model.refreshHealth() } }
            Task { await model.refreshOllamaModels() }
        }
    }

    @ViewBuilder private var bottomNavigationButton: some View {
        if step == 1 {
            // Runtime step navigation
            if model.health != nil {
                Button("Continue to Speech Models →") { step += 1 }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else if model.setupBusy && model.activeDownload == nil {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Installing Runtime…")
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: Theme.Radius.m))
                .foregroundStyle(.secondary)
            } else {
                Button("Install Runtime to Continue") { model.installRuntime() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.modelChangesAllowed)
                    .help("Install the local runtime before continuing to model downloads.")
            }
        } else if step < steps.count - 1 {
            Button(step == 0 ? "Get Started" : "Continue") { step += 1 }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        } else {
            Button("Finish Later") { model.dismissOnboarding() }
            Button("Start First Meeting") { startFirstMeeting() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.newMeetingBlockedReason != nil)
                .help(model.newMeetingBlockedReason ?? "Choose inputs and start recording")
        }
    }

    @ViewBuilder private var page: some View {
        switch step {
        case 0: welcome
        case 1: runtime
        case 2: speech
        case 3: notesAndOllama
        case 4: permissions
        default: ready
        }
    }

    private func header(_ title: String, _ subtitle: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Image(systemName: systemImage).font(.system(size: 30, weight: .light)).foregroundStyle(Theme.accent)
            Text(title).font(Theme.Font.pageTitle)
            Text(subtitle).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                BrandMark(size: 46)
                Text("Welcome to Echo Voice").font(Theme.Font.hero)
                Text("Record online meetings or conversations in the room, then review transcripts, summaries, and action items linked to what was said. Everything is processed 100% locally on this Mac.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SectionCard("Setup Roadmap", subtitle: "What Echo Voice prepares for offline operation", systemImage: "checklist") {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    setupLine("desktopcomputer", "1. Local Speech Runtime", "One-time setup; required for models")
                    setupLine("waveform", "2. Speech Recognition Model", speechSizeRange)
                    setupLine("brain.head.profile", "3. Meeting Notes & Ollama", "Native MLX or local Ollama")
                    setupLine("mic", "4. Audio Permissions", "Microphone & app capture")
                }
            }
            Label("All audio, transcripts, and notes remain on this Mac. No audio or telemetry is ever sent to external cloud services.", systemImage: "lock.shield")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func setupLine(_ icon: String, _ text: String, _ detail: String) -> some View {
        HStack {
            Image(systemName: icon).frame(width: 22).foregroundStyle(Theme.accent)
            Text(text).font(.callout.weight(.medium))
            Spacer()
            Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private var speechSizeRange: String {
        let sizes = (model.catalog?.models(for: .speech) ?? []).map { model.catalog?.downloadBytes(includingDependenciesOf: $0.id) ?? $0.download_bytes }
        guard let low = sizes.min(), let high = sizes.max() else { return "" }
        return ByteCountFormatter.string(fromByteCount: low, countStyle: .file) + " – " + ByteCountFormatter.string(fromByteCount: high, countStyle: .file)
    }

    private var runtime: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            header(
                "Local speech runtime",
                "Echo Voice runs all speech recognition and AI processing locally on this Mac. The local runtime must be installed and verified before speech models can be downloaded.",
                systemImage: "desktopcomputer"
            )

            // Two-phase explanation card
            HStack(spacing: Theme.Space.m) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Circle().fill(model.health != nil ? Color.green : Theme.accent).frame(width: 8, height: 8)
                        Text("Phase 1: Local Runtime").font(.subheadline.weight(.semibold))
                    }
                    Text("Prepares local Python & Apple Silicon MLX environment.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Space.m)
                .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: Theme.Radius.m))

                Image(systemName: "arrow.right").foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Circle().fill(model.isModelReady(model.defaultModel(.speech)) ? Color.green : Color.secondary).frame(width: 8, height: 8)
                        Text("Phase 2: Speech Models").font(.subheadline.weight(.semibold))
                    }
                    Text("Downloads Parakeet or Whisper once runtime is ready.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Space.m)
                .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: Theme.Radius.m))
            }

            SectionCard {
                if model.health != nil {
                    HStack(alignment: .center, spacing: Theme.Space.l) {
                        Image(systemName: "checkmark.seal.fill").font(.system(size: 38)).foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Local Runtime Ready").font(.headline)
                                StatusBadge(text: "Ready", tone: .ready)
                            }
                            Text(model.runtimeBundled ? "The included local speech runtime is verified and active." : "The local runtime is installed and operational on this Mac.")
                                .font(.callout).foregroundStyle(.secondary)
                            Text("You can now proceed to select and download your speech recognition model.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, Theme.Space.s)
                } else if model.setupBusy && model.activeDownload == nil {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        HStack(spacing: Theme.Space.m) {
                            ProgressView().controlSize(.small)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Setting up local runtime…").font(.headline)
                                Text(model.setupProgress).font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Cancel") { model.cancelSetup() }.controlSize(.small)
                        }
                        ProgressView().progressViewStyle(.linear)
                        Text("Configuring dependencies in your app data folder. Model downloads will unlock automatically once this completes.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, Theme.Space.s)
                } else if !model.runtimeChecked {
                    HStack(spacing: Theme.Space.m) {
                        ProgressView().controlSize(.small)
                        Text("Checking local speech runtime…").font(.headline)
                        Spacer()
                    }
                    .padding(.vertical, Theme.Space.s)
                } else {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        HStack(alignment: .top, spacing: Theme.Space.m) {
                            Image(systemName: "wrench.and.screwdriver.fill").font(.system(size: 32)).foregroundStyle(Theme.accent)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Local Runtime Setup Required").font(.headline)
                                Text("Echo Voice uses an isolated on-device ML runtime to transcribe audio. All execution happens on this Mac; meeting content never touches external servers.")
                                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        HStack(spacing: Theme.Space.m) {
                            Button("Install Local Runtime") {
                                model.installRuntime()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .disabled(!model.modelChangesAllowed)

                            Button("Check Again") {
                                Task { await model.refreshHealth() }
                            }
                            .controlSize(.large)
                        }
                    }
                    .padding(.vertical, Theme.Space.s)
                }
            }

            Label("All runtime components are stored locally in the Echo Voice application support directory.", systemImage: "lock.shield")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var speech: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            header("Choose a speech model", "This model turns your recordings into text. You can add or switch models later in Settings.", systemImage: "waveform")

            if model.health == nil {
                if model.setupBusy && model.activeDownload == nil {
                    Banner(
                        message: "Local runtime setup is in progress (\(model.setupProgress)). Model downloads will unlock automatically once runtime is ready.",
                        systemImage: "hourglass",
                        tone: .progress
                    )
                } else {
                    Banner(
                        message: "The local runtime must be installed before downloading speech models.",
                        systemImage: "exclamationmark.triangle",
                        tone: .attention
                    ) {
                        Button("Install Runtime") { model.installRuntime() }.controlSize(.small)
                    }
                }
            } else if model.isModelReady(speechChoice) {
                Banner(
                    message: "\(model.catalog?.model(speechChoice)?.displayName ?? "Speech model") is ready for offline transcription.",
                    systemImage: "checkmark.circle.fill",
                    tone: .ready
                )
            }

            ModelOptionCards(role: .speech, selection: $speechChoice)
            if let entry = model.catalog?.model(speechChoice) {
                ModelActions(entry: entry, alwaysMakeDefault: true).id(entry.id)
            }
            if model.activeDownload != nil {
                Text("You can continue while the model downloads. Recording becomes available when downloads finish.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var notesAndOllama: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            header(
                "Meeting notes & Ollama",
                "Echo Voice can generate summaries, key decisions, and action items after recording. Choose built-in models, connect to your own local Ollama models, or skip notes.",
                systemImage: "sparkles"
            )

            SectionCard("Meeting Notes Engine", subtitle: "Select your preferred local intelligence provider", systemImage: "brain.head.profile") {
                Picker("Notes Provider", selection: $notesChoiceType) {
                    Text("Built-in Local Models").tag(0)
                    Text("Ollama (Local Server)").tag(1)
                    Text("Off (Transcripts Only)").tag(2)
                }
                .pickerStyle(.segmented)
                .onChange(of: notesChoiceType) { _, newType in
                    if newType == 1 {
                        Task { await model.refreshOllamaModels() }
                    } else if newType == 2 {
                        model.setDefaultNotes(nil)
                        notesChoice = ""
                    } else if newType == 0 {
                        if notesChoice.isEmpty {
                            notesChoice = model.catalog?.model("notes")?.id ?? model.catalog?.models(for: .notes).first?.id ?? ""
                        }
                        if let entry = model.catalog?.model(notesChoice), model.isModelReady(entry.id) {
                            model.setDefaultNotes(ModelSelection(id: entry.id, revision: entry.revision, provider: .native))
                        }
                    }
                }

                if notesChoiceType == 0 {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        Text("Runs directly using Apple Silicon MLX with zero external services.")
                            .font(.caption).foregroundStyle(.secondary)
                        ModelOptionCards(role: .notes, selection: $notesChoice)
                        if let entry = model.catalog?.model(notesChoice) {
                            ModelActions(entry: entry, alwaysMakeDefault: true).id(entry.id)
                        }
                    }
                } else if notesChoiceType == 1 {
                    ollamaSection
                } else {
                    HStack(spacing: Theme.Space.m) {
                        StatusBadge(text: "Notes Off", tone: .neutral)
                        Text("Meeting notes will not be generated automatically. Verbatim transcripts will still be recorded and transcribed. You can enable notes anytime in Settings.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, Theme.Space.s)
                }
            }

            SectionCard(ModelRole.speakers.title, subtitle: ModelRole.speakers.purpose, systemImage: ModelRole.speakers.symbol, trailing: AnyView(offButton(.speakers))) {
                ModelOptionCards(role: .speakers, selection: $speakersChoice)
                if let entry = model.catalog?.model(speakersChoice) {
                    ModelActions(entry: entry, alwaysMakeDefault: true).id(entry.id)
                }
            }
        }
    }

    private var ollamaSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                Label(model.ollamaStatus, systemImage: model.ollamaModels.isEmpty ? "exclamationmark.circle" : "checkmark.circle")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(model.ollamaModels.isEmpty ? .orange : .green)
                Spacer()
                Button(model.refreshingOllama ? "Checking…" : "Refresh Models") {
                    Task { await model.refreshOllamaModels() }
                }
                .disabled(model.refreshingOllama)
                .controlSize(.small)
            }

            if model.refreshingOllama {
                HStack(spacing: Theme.Space.s) {
                    ProgressView().controlSize(.small)
                    Text("Connecting to Ollama on localhost:11434…").font(.caption).foregroundStyle(.secondary)
                }
            } else if !model.ollamaModels.isEmpty {
                Text("Select an installed model to generate summaries and action items:")
                    .font(.caption).foregroundStyle(.secondary)

                VStack(spacing: Theme.Space.s) {
                    ForEach(model.ollamaModels) { entry in
                        let isSelected = selectedOllama == entry.name
                        Button {
                            selectedOllama = entry.name
                            model.setDefaultNotes(ModelSelection(id: entry.name, revision: entry.digest, provider: .ollama))
                        } label: {
                            HStack(spacing: Theme.Space.m) {
                                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(isSelected ? Theme.accent : .secondary)
                                    .font(.title3)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: Theme.Space.s) {
                                        Text(entry.name).font(.callout.weight(.semibold))
                                        if isSelected {
                                            StatusBadge(text: "Default", tone: .progress)
                                        }
                                    }
                                    HStack(spacing: Theme.Space.m) {
                                        Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                        Text("Digest: " + entry.digest.prefix(12) + "…")
                                            .font(.caption2.monospaced()).foregroundStyle(.tertiary)
                                    }
                                }
                                Spacer()
                                StatusBadge(text: "Installed in Ollama", tone: .ready)
                            }
                            .padding(Theme.Space.m)
                            .contentShape(Rectangle())
                            .background(isSelected ? Theme.accent.opacity(0.08) : Theme.subtleFill, in: RoundedRectangle(cornerRadius: Theme.Radius.m))
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m).strokeBorder(isSelected ? Theme.accent.opacity(0.6) : Theme.cardStroke))
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else if model.ollamaChecked && !model.ollamaStatus.contains("Could not connect") {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text("Ollama is running, but no models are installed yet.")
                        .font(.callout.weight(.medium)).foregroundStyle(.orange)
                    Text("Run the following in Terminal to install a lightweight, fast model:")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text("ollama run llama3.2").font(.caption.monospaced()).textSelection(.enabled)
                        Spacer()
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("ollama run llama3.2", forType: .string)
                        }.controlSize(.mini)
                    }
                    .padding(Theme.Space.s)
                    .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: Theme.Radius.s))
                }
                .padding(Theme.Space.m)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.m))
            } else {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text("Ollama is not running on localhost:11434.")
                        .font(.callout.weight(.medium)).foregroundStyle(.orange)
                    Text("Make sure the Ollama application is launched, or run `ollama serve` in Terminal.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: Theme.Space.m) {
                        Button("Check Connection") {
                            Task { await model.refreshOllamaModels() }
                        }
                        .controlSize(.small)
                        Button("Use Built-in Models Instead") {
                            notesChoiceType = 0
                        }
                        .controlSize(.small)
                    }
                }
                .padding(Theme.Space.m)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.m))
            }

            Label("Echo Voice connects only to Ollama on this Mac. No data ever leaves your device.", systemImage: "lock.shield")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func offButton(_ role: ModelRole) -> some View {
        let isOff = role == .notes ? model.defaultNotesSelection() == nil : model.defaultModel(role).isEmpty
        if isOff { StatusBadge(text: "Off", tone: .neutral) }
        else {
            Button("Turn Off") {
                if role == .notes { model.setDefaultNotes(nil); notesChoice = "" } else { model.setDefaultModel("", role: role); speakersChoice = "" }
            }.controlSize(.small)
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            header("Permissions", "macOS asks before Echo Voice can hear anything. Recording always needs your explicit start and consent.", systemImage: "hand.raised")
            SectionCard {
                PermissionRow(kind: .microphone)
                Divider()
                PermissionRow(kind: .meetingAudio)
            }
            Label("For online meetings, Echo Voice records only the application you select. It never captures all apps or your screen.", systemImage: "app.badge.checkmark")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var ready: some View {
        let readiness = model.readiness
        return VStack(alignment: .leading, spacing: Theme.Space.xl) {
            header(readiness.requiredComplete ? "You're ready" : "Almost there",
                   readiness.requiredComplete ? "Start a meeting whenever you like. Optional items can be finished later from the status indicator in the sidebar." : "Recording works now; audio is saved and transcription waits until a speech model is ready.",
                   systemImage: readiness.requiredComplete ? "checkmark.seal" : "hourglass")
            SectionCard { SetupChecklistView() }
            if let reason = model.newMeetingBlockedReason { Banner(message: reason, systemImage: "info.circle", tone: .neutral) }
        }
    }

    private func startFirstMeeting() {
        model.dismissOnboarding()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { model.showNewMeeting = true }
    }
}
