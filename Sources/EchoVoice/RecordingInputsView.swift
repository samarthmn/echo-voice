import SwiftUI
import EchoCore

struct RecordingInputsView: View {
    @EnvironmentObject private var model: AppModel
    let meetingID: String
    @Environment(\.dismiss) private var dismiss
    @State private var microphoneUID = ""
    @State private var applicationID = ""
    @State private var acousticMode: CaptureAcousticMode = .headphones
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Recording inputs").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.disabled(working)
            }
            Text("Choose an input explicitly when a device or meeting application changes. The other available track keeps recording.")
                .font(.callout).foregroundStyle(.secondary)
            Form {
                Picker("Microphone", selection: $microphoneUID) {
                    Text("Choose a microphone").tag("")
                    ForEach(model.microphones) { device in Text(device.name).tag(device.id) }
                }
                Button("Use selected microphone") {
                    working = true
                    Task { await model.changeMicrophone(uid: microphoneUID); working = false }
                }.disabled(working || microphoneUID.isEmpty)
                if model.meetings.first(where: { $0.id == meetingID })?.recordingMode == .online {
                    Picker("Meeting application", selection: $applicationID) {
                        Text("Choose an application").tag("")
                        ForEach(model.sources) { source in Text(source.name).tag(source.id) }
                    }
                    Button("Use selected application") {
                        working = true
                        Task { await model.changeApplication(sourceID: applicationID); working = false }
                    }.disabled(working || applicationID.isEmpty)
                    Picker("Listening setup", selection: $acousticMode) {
                        Text("Headphones").tag(CaptureAcousticMode.headphones)
                        Text("Speakerphone").tag(CaptureAcousticMode.speakerphone)
                    }
                    Button("Use listening setup") {
                        working = true
                        Task { await model.setAcousticMode(acousticMode); working = false }
                    }.disabled(working || acousticMode == model.acousticMode)
                }
            }.formStyle(.grouped)
            HStack {
                Text(model.microphoneMuted ? "Microphone is muted in Echo Voice." : "Microphone is recording in Echo Voice.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Refresh Inputs") { model.refreshSources() }
            }
        }
        .padding(24)
        .frame(width: 540)
        .disabled(model.recordingID != meetingID)
        .interactiveDismissDisabled(working)
        .alert("Input change failed", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .onAppear {
            model.refreshSources()
            microphoneUID = model.recordingMicrophoneUID ?? ""
            applicationID = model.recordingApplicationID ?? ""
            acousticMode = model.acousticMode
        }
    }
}
