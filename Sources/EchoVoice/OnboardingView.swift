import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Label("Welcome to Echo Voice", systemImage: "waveform").font(.title2.weight(.semibold))
                Text("Record now. Add local transcription and notes when you’re ready.")
                    .foregroundStyle(.secondary)
            }.padding(24)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Label("Your audio and meeting content stay on this Mac.", systemImage: "lock.shield")
                        .font(.callout)
                    SetupChecklistView()
                    Button("Choose Models and Optional Features…") {
                        model.settingsPage = .models; openSettings()
                    }
                    Text("Model downloads start only when you choose them. Microphone access is requested when you allow it or begin recording.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(24)
            }
            Divider()
            HStack {
                Button("Finish Later") { model.dismissOnboarding() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("New Meeting") { model.dismissOnboarding(); model.showNewMeeting = true }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(model.newMeetingBlockedReason != nil)
            }.padding(20)
        }
        .frame(width: 580, height: 570)
        .onAppear { model.refreshPermissions() }
        .alert("Setup needs attention", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}
