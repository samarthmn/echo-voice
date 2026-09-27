import SwiftUI
import EchoCapture
import EchoCore

struct StartMeetingView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @State private var selectedSpeechModel = ""
    @State private var selectedSpeakerModel = ""
    @State private var selectedMode: RecordingMode = .online
    @State private var previewConfiguration: ProcessingConfiguration?
    private var mode: RecordingMode { resumeID.flatMap { id in model.meetings.first { $0.id == id }?.recordingMode } ?? selectedMode }
    private var speechModel: SpeechRecognitionModel {
        if let resumeID, let saved = model.meetings.first(where: { $0.id == resumeID }) { return saved.recognitionModel }
        return SpeechRecognitionModel(rawValue: selectedSpeechModel) ?? .whisper
    }
    @State private var title = ""
    @State private var applicationID = ""
    @State private var microphoneID = ""
    @State private var startMicrophoneMuted = false
    @AppStorage("liveTranscriptionAtStart") private var liveTranscriptionAtStart = true
    @State private var singleSource = false
    @State private var speakers = true
    @State private var consent = false
    @State private var starting = false
    @State private var resumeID: String?
    private var application: AudioSource? { mode == .inPerson ? nil : model.sources.first { $0.id == applicationID } }
    private var microphone: MicrophoneDevice? { model.microphones.first { $0.id == microphoneID } }
    private var validInputs: Bool { mode == .inPerson ? microphone != nil : (application != nil && microphone != nil) || (singleSource && (application != nil || microphone != nil)) }
    private var interrupted: [Meeting] { model.meetings.filter { $0.state == .interrupted } }

    private var startDisabledReason: String? {
        if let reason = model.newMeetingBlockedReason { return reason }
        if resumeID == nil && SpeechRecognitionModel(rawValue: selectedSpeechModel) == nil { return "Choose a speech model." }
        if resumeID == nil && !selectedSpeakerModel.isEmpty && model.health?.models[selectedSpeakerModel]?.ready != true {
            return "Set up the selected speaker-grouping model, or turn speaker grouping off."
        }
        if !validInputs {
            if mode == .inPerson { return "Choose a room microphone." }
            return singleSource ? "Choose an application or a microphone." : "Choose a meeting application and a microphone, or allow a single source."
        }
        if model.testingInputs { return "Wait for the input test to finish." }
        if !consent { return "Confirm that you have consent to record." }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(resumeID == nil ? "Start a meeting" : "Resume a meeting").font(Theme.Font.pageTitle)
                    Text("Choose what to capture. Everything stays on this Mac.").foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.title2) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .disabled(starting || model.testingInputs).accessibilityLabel("Close").keyboardShortcut(.cancelAction)
            }
            .padding([.horizontal, .top], Theme.Space.xl).padding(.bottom, Theme.Space.m)
            notices.padding(.horizontal, Theme.Space.xl)
            Form {
                Section {
                    Picker("Record", selection: $selectedMode) {
                        ForEach(RecordingMode.allCases, id: \.self) { mode in
                            Label(mode.displayName, systemImage: mode == .inPerson ? "person.2" : "video").tag(mode)
                        }
                    }.pickerStyle(.segmented).disabled(resumeID != nil)
                        .onChange(of: selectedMode) { _, _ in resetTest() }
                    TextField("Meeting title", text: $title).disabled(resumeID != nil)
                    if !interrupted.isEmpty {
                        Picker("Resume saved meeting", selection: $resumeID) {
                            Text("Create a new meeting").tag(String?.none)
                            ForEach(interrupted) { Text($0.title).tag(Optional($0.id)) }
                        }.onChange(of: resumeID) { _, id in
                            if let saved = model.meetings.first(where: { $0.id == id }) {
                                selectedMode = saved.recordingMode; speakers = saved.usesEchoCancellation
                                if let settings = try? model.store?.captureSessionSettings(meetingID: saved.id) {
                                    microphoneID = settings.microphoneUID ?? microphoneID
                                    applicationID = settings.applicationID ?? applicationID
                                    startMicrophoneMuted = settings.microphoneMuted
                                    speakers = settings.acousticMode == .speakerphone
                                }
                            } else {
                                startMicrophoneMuted = false
                            }
                            refreshPreview()
                        }
                    }
                }
                Section {
                    if mode == .online {
                        Picker("Meeting application", selection: $applicationID) {
                            Text("Choose an application").tag("")
                            ForEach(model.sources) { Text($0.name).tag($0.id) }
                        }.onChange(of: applicationID) { _, _ in resetTest() }
                    }
                    Picker(mode.microphoneLabel, selection: $microphoneID) {
                        Text("No microphone").tag("")
                        ForEach(model.microphones) { Text($0.name).tag($0.id) }
                    }.onChange(of: microphoneID) { _, _ in resetTest() }
                    if resumeID == nil {
                        Toggle("Start with microphone muted in Echo Voice", isOn: $startMicrophoneMuted)
                            .help("Meeting application audio continues. Your microphone is not saved while muted.")
                    } else {
                        LabeledContent("Microphone on resume", value: startMicrophoneMuted ? "Muted" : "Unmuted")
                    }
                    if mode == .online {
                        Toggle("Using speakers (remove meeting audio from microphone transcript)", isOn: Binding(
                            get: { speakers && application != nil && microphone != nil }, set: { speakers = $0 }))
                            .disabled(application == nil || microphone == nil)
                        Toggle("I explicitly want to record only one audio source", isOn: $singleSource)
                    }
                } header: { Text("Inputs") } footer: {
                    HStack(alignment: .firstTextBaseline) {
                        Text(mode == .online ? "Open Meet, Zoom, or Teams before choosing it. Browser capture may include audio from other tabs in that browser." : "Choose the microphone that will hear everyone. Speaker labels are added after recording; overlapping voices may be hard to separate.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Refresh Sources") { model.refreshSources() }.controlSize(.small)
                    }
                }
                if resumeID == nil {
                    Section {
                        Toggle("Live transcription", isOn: $liveTranscriptionAtStart)
                        Text(liveTranscriptionAtStart
                             ? "Show the transcript while recording. You can stop live transcription during the meeting."
                             : "Your transcript will be generated after the recording ends.")
                            .font(.caption).foregroundStyle(.secondary)
                    } header: { Text("Transcript timing") }
                }
                Section {
                    if resumeID == nil {
                        Picker("Speech recognition", selection: $selectedSpeechModel) {
                            Text("Choose a model").tag("")
                            ForEach(SpeechRecognitionModel.allCases, id: \.rawValue) { option in
                                Text(option.displayName + (model.isModelReady(option.assetKey) ? "" : " — not downloaded")).tag(option.rawValue)
                            }
                        }
                    } else {
                        LabeledContent("Speech recognition", value: speechModel.displayName)
                    }
                    ModelSummaryView(title: "Models for this meeting", configuration: previewConfiguration)
                    if resumeID == nil {
                        Picker("Group speakers after recording", selection: $selectedSpeakerModel) {
                            Text("Off").tag("")
                            ForEach(model.catalog?.models(for: .speakers) ?? []) { option in
                                Text(option.displayName + (model.health?.models[option.id]?.ready == true ? "" : " — setup needed"))
                                    .tag(option.id)
                            }
                        }.onChange(of: selectedSpeakerModel) { _, _ in refreshPreview() }
                        Text("Speaker names are assigned after the meeting and can be reviewed with voice samples.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } header: { Text("Processing") }
                Section {
                    HStack(spacing: Theme.Space.xl) {
                        LevelMeter(name: mode.microphoneLabel, level: model.microphoneLevel)
                        if mode == .online { LevelMeter(name: "Meeting audio", level: model.remoteLevel) }
                        Spacer()
                        Button(model.testingInputs ? "Testing…" : "Test Inputs · 5 s") {
                            Task { await model.testInputs(application: application, microphone: microphone, singleSource: singleSource, mode: mode) }
                        }.disabled(!validInputs || model.testingInputs || starting)
                    }
                    if model.cancellingPreparation { Text("Cancelling… waiting for the audio device to finish safely.").font(.caption).foregroundStyle(.secondary) }
                    if model.inputTestPassed { Label("Input test completed", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green) }
                } header: { Text("Test inputs — optional") } footer: {
                    Text(mode == .inPerson ? "Speak near the microphone. Test recordings are discarded." : "Speak and play sound in the meeting application during the test. Test recordings are discarded.").font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Toggle(isOn: $consent) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("I have consent to record this meeting").font(.callout.weight(.medium))
                            Text("Ensure meeting participants are aware audio is being recorded locally.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(starting)
            Divider()
            HStack {
                Label("Audio and transcripts stay on this Mac.", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(model.cancellingPreparation ? "Cancelling…" : "Cancel") {
                    if starting || model.testingInputs { model.cancelPreparation() } else { dismiss() }
                }.disabled(model.cancellingPreparation)
                Button(starting ? "Starting…" : "Start Recording") {
                    starting = true
                    Task { await model.startMeeting(title: title, application: application, microphone: microphone, singleSource: singleSource, echoCancellation: speakers, consent: consent, speechModel: speechModel, resumeID: resumeID, mode: mode, microphoneMuted: startMicrophoneMuted, liveTranscription: liveTranscriptionAtStart, speakerModelID: selectedSpeakerModel); starting = false }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(startDisabledReason != nil || starting)
                .help(startDisabledReason ?? "Start recording")
            }
            .padding(.horizontal, Theme.Space.xl).padding(.vertical, Theme.Space.l)
        }
        .frame(minWidth: 640, idealWidth: 680, minHeight: 560, idealHeight: 760)
        .interactiveDismissDisabled(model.testingInputs || starting)
        .alert("Echo Voice", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .onAppear {
            selectedSpeechModel = initialSpeechModel()
            selectedSpeakerModel = model.defaultModel(.speakers)
            selectedMode = RecordingMode(rawValue: UserDefaults.standard.string(forKey: "lastRecordingMode") ?? "") ?? .online
            model.refreshSources(); model.refreshPermissions()
            title = "Meeting · " + Date().formatted(date: .abbreviated, time: .shortened)
            microphoneID = (model.microphones.first { $0.isBuiltIn } ?? model.microphones.first { $0.isDefault } ?? model.microphones.first)?.id ?? ""
            model.inputTestPassed = false
            refreshPreview()
        }
        .onChange(of: selectedSpeechModel) { _, _ in refreshPreview() }
    }

    @ViewBuilder private var notices: some View {
        VStack(spacing: Theme.Space.s) {
            if let reason = model.newMeetingBlockedReason {
                Banner(message: reason, systemImage: "arrow.down.circle", tone: .progress) {
                    // Cancelling only the active download would start the next queued one.
                    if model.activeDownload != nil { Button(model.queuedDownloads.isEmpty ? "Cancel Download" : "Cancel Downloads") { model.cancelSetup() }.controlSize(.small) }
                }
            }
            if microphone != nil && model.microphonePermission == .denied {
                Banner(message: "Microphone access is denied. Allow Echo Voice in System Settings, or choose No microphone with single-source recording.", tone: .problem) {
                    Button("Open System Settings") { SystemSettings.openMicrophonePrivacy() }.controlSize(.small)
                }
            } else if microphone != nil && model.microphonePermission == .notDetermined {
                Banner(message: "macOS will ask for microphone access when you test inputs or start recording.", systemImage: "mic", tone: .neutral)
            }
            if model.health?.canTranscribe(speechModel) != true {
                Banner(message: "\(speechModel.displayName) isn't ready yet. Audio will be saved and transcription queued until setup is complete.", systemImage: "arrow.down.circle") {
                    Button("Set Up Models") { model.settingsPage = .models; model.settingsModelRole = .speech; openSettings() }.controlSize(.small)
                }
            }
        }
    }

    /// Prefer the default, then any downloaded model, so a fresh choice can transcribe immediately.
    private func initialSpeechModel() -> String {
        let saved = model.defaultModel(.speech)
        let preferred = SpeechRecognitionModel.allCases.first { $0.assetKey == saved } ?? .parakeet
        if model.isModelReady(preferred.assetKey) { return preferred.rawValue }
        return (SpeechRecognitionModel.allCases.first { model.isModelReady($0.assetKey) } ?? preferred).rawValue
    }
    private func resetTest() { model.inputTestPassed = false }
    private func refreshPreview() {
        if let resumeID { previewConfiguration = try? model.store?.configuration(meetingID: resumeID) }
        else { previewConfiguration = try? model.processingConfiguration(speech: speechModel, speakerModelID: selectedSpeakerModel) }
    }
}
