import SwiftUI
import EchoCapture
import EchoCore

struct StartMeetingView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    let resumeID: String?
    @State private var mode: RecordingMode = .online
    @State private var title = ""
    @State private var applicationID = ""
    @State private var microphoneID = ""
    @State private var microphoneMuted = false
    @State private var acousticMode: CaptureAcousticMode = .headphones
    @State private var singleSource = false
    @State private var consent = false
    @State private var starting = false
    @State private var advanced = false
    @State private var testing = false
    @State private var speech: SpeechRecognitionModel = .parakeet
    @State private var speakerModel = ""
    @AppStorage("liveTranscriptionAtStart") private var liveTranscription = true

    init(resumeID: String? = nil) { self.resumeID = resumeID }
    private var application: AudioSource? { mode == .online ? model.sources.first { $0.id == applicationID } : nil }
    private var microphone: MicrophoneDevice? { model.microphones.first { $0.id == microphoneID } }
    private var validInputs: Bool {
        mode == .inPerson ? microphone != nil : singleSource ? application != nil || microphone != nil : application != nil && microphone != nil
    }
    private var reason: String? {
        if starting { return nil }
        if let reason = model.newMeetingBlockedReason { return reason }
        if !validInputs { return mode == .inPerson ? "Choose a room microphone." : "Choose an application and microphone, or explicitly enable single-source recording." }
        if microphone != nil && model.microphonePermission == .denied { return "Allow microphone access in System Settings, then return here." }
        if !consent { return "Confirm participant consent to start recording." }
        return nil
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(resumeID == nil ? "New Meeting" : "Resume Recording").font(.title2.weight(.semibold))
                    Text("Choose your audio. Everything stays on this Mac.").foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(24)
            Form {
                Section {
                    Picker("Meeting type", selection: $mode) {
                        Text("Online meeting").tag(RecordingMode.online)
                        Text("In person").tag(RecordingMode.inPerson)
                    }.pickerStyle(.segmented).disabled(resumeID != nil)
                    TextField("Title", text: $title).disabled(resumeID != nil)
                }
                Section("Audio sources") {
                    if mode == .online {
                        Picker("Meeting application", selection: $applicationID) {
                            Text("Choose an application").tag("")
                            ForEach(model.sources) { Text($0.name).tag($0.id) }
                        }
                    }
                    Picker(mode == .inPerson ? "Room microphone" : "Microphone", selection: $microphoneID) {
                        Text("No microphone").tag("")
                        ForEach(model.microphones) { Text($0.name).tag($0.id) }
                    }
                    if mode == .online {
                        Picker("Listening with", selection: $acousticMode) {
                            Text("Headphones").tag(CaptureAcousticMode.headphones)
                            Text("Speakers · echo cancellation").tag(CaptureAcousticMode.speakerphone)
                        }.disabled(application == nil || microphone == nil)
                        Toggle("Record only one audio source", isOn: $singleSource)
                        Text("Select the browser for a web meeting. Other audible tabs in that browser may also be recorded.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if resumeID == nil {
                        Toggle("Start with Echo Voice’s microphone muted", isOn: $microphoneMuted).disabled(microphone == nil)
                    } else { LabeledContent("Microphone on resume", value: microphoneMuted ? "Muted" : "Unmuted") }
                    HStack {
                        if model.microphonePermission == .denied {
                            Button("Open Microphone Settings") { SystemSettings.openMicrophonePrivacy() }
                        }
                        Spacer()
                        Button("Refresh Sources") { model.refreshSources(); model.refreshPermissions() }
                    }
                }
                if resumeID == nil {
                    Section {
                        Toggle("Show live transcription", isOn: $liveTranscription)
                        Text("Audio is saved even when transcription is unavailable. You can stop live transcription for the rest of the meeting.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                DisclosureGroup("Models for this meeting", isExpanded: $advanced) {
                    Picker("Speech recognition", selection: $speech) {
                        ForEach(SpeechRecognitionModel.allCases, id: \.self) { option in
                            Text(option.displayName + (model.isModelReady(option.assetKey) ? "" : " · setup needed")).tag(option)
                        }
                    }.disabled(resumeID != nil)
                    Picker("Speaker grouping", selection: $speakerModel) {
                        Text("Off").tag("")
                        ForEach(model.catalog?.models(for: .speakers) ?? []) { option in
                            Text(option.displayName + (model.isModelReady(option.id) ? "" : " · setup needed")).tag(option.id)
                        }
                    }.disabled(resumeID != nil)
                    ModelSummaryView(title: "Saved configuration", configuration: configuration)
                    Button("Manage Models…") { model.settingsPage = .models; openSettings() }
                }
                if !model.isModelReady(speech.assetKey) {
                    Label("Speech model needs setup. Recording is available; transcription will wait.", systemImage: "arrow.down.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup("Test audio inputs (optional)", isExpanded: $testing) {
                    InputTestMeters(session: model.recordingSession, online: mode == .online)
                    Button(model.testingInputs ? "Testing…" : "Test for 5 Seconds") {
                        Task { await model.testInputs(application: application, microphone: microphone, singleSource: singleSource, mode: mode) }
                    }.disabled(!validInputs || model.testingInputs || starting)
                    if model.inputTestPassed { Label("Input test completed", systemImage: "checkmark.circle").font(.caption) }
                    Text("Speak and play meeting audio during the test. Test audio is discarded.").font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Toggle("I have participant consent to record", isOn: $consent)
                        .accessibilityIdentifier("recording-consent")
                }
            }.formStyle(.grouped).disabled(starting)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if let reason { Text(reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                HStack {
                    Label("Local recording", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(model.cancellingPreparation ? "Cancelling…" : "Cancel") {
                        if starting || model.testingInputs { model.cancelPreparation() } else { dismiss() }
                    }.keyboardShortcut(.cancelAction).disabled(model.cancellingPreparation)
                    Button(starting ? "Starting…" : "Start Recording") {
                        starting = true
                        let request = RecordingRequest(title: title, application: application, microphone: microphone,
                            singleSource: singleSource, acousticMode: mode == .online ? acousticMode : .headphones,
                            consent: consent, speechModel: speech, resumeID: resumeID, mode: mode,
                            microphoneMuted: microphoneMuted, liveTranscription: liveTranscription, speakerModelID: speakerModel)
                        Task { await model.startMeeting(request); starting = false }
                    }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(reason != nil || starting || model.testingInputs).accessibilityIdentifier("start-recording")
                }
            }.padding(20)
        }
        .frame(width: 620, height: 580)
        .interactiveDismissDisabled(starting || model.testingInputs)
        .alert("Recording needs attention", isPresented: Binding(get: { model.recordingError != nil }, set: { if !$0 { model.recordingError = nil } })) {
            Button("OK") { model.recordingError = nil }
        } message: { Text(model.recordingError ?? "") }
        .onAppear(perform: prepare)
        .onChange(of: applicationID) { _, _ in model.inputTestPassed = false }
        .onChange(of: microphoneID) { _, _ in model.inputTestPassed = false }
        .onChange(of: mode) { _, _ in model.inputTestPassed = false; singleSource = false; acousticMode = .headphones }
    }
    private var configuration: ProcessingConfiguration? {
        if let resumeID { return try? model.store?.configuration(meetingID: resumeID) }
        return try? model.processingConfiguration(speech: speech, speakerModelID: speakerModel)
    }
    private func prepare() {
        model.refreshSources(); model.refreshPermissions(); model.inputTestPassed = false
        title = "Meeting · " + Date().formatted(date: .abbreviated, time: .shortened)
        speech = model.defaultModel(.speech) == "asr" ? .whisper : .parakeet
        speakerModel = model.defaultModel(.speakers)
        mode = RecordingMode(rawValue: UserDefaults.standard.string(forKey: "lastRecordingMode") ?? "") ?? .online
        microphoneID = (model.microphones.first { $0.isBuiltIn } ?? model.microphones.first { $0.isDefault } ?? model.microphones.first)?.id ?? ""
        if let resumeID, let saved = model.meetings.first(where: { $0.id == resumeID }) {
            title = saved.title; mode = saved.recordingMode; speech = saved.recognitionModel
            if let settings = try? model.store?.captureSessionSettings(meetingID: resumeID) {
                microphoneID = settings.microphoneUID ?? ""; applicationID = settings.applicationID ?? ""
                microphoneMuted = settings.microphoneMuted; acousticMode = settings.acousticMode
                singleSource = mode == .online && (settings.microphoneUID == nil || settings.applicationID == nil)
            }
            speakerModel = configuration?.speakers?.id ?? ""
        }
    }
}

private struct InputTestMeters: View {
    @ObservedObject var session: RecordingSessionModel
    let online: Bool
    var body: some View {
        HStack {
            LevelMeter(name: "Microphone", level: session.microphoneLevel)
            if online { LevelMeter(name: "Meeting audio", level: session.remoteLevel) }
        }
    }
}
