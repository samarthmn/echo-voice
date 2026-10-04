import SwiftUI
import EchoCore

struct WelcomeView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let readiness = model.readiness
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                if let recovery = model.libraryRecovery {
                    Banner(message: recovery, tone: .problem).textSelection(.enabled)
                } else if model.store == nil {
                    HStack(spacing: Theme.Space.s) { ProgressView().controlSize(.small); Text(model.status).font(.callout).foregroundStyle(.secondary) }
                }
                BrandMark(size: 48)
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text("Your meetings, on your Mac.").font(Theme.Font.hero)
                }
                Text("Record meeting audio and your microphone, follow the transcript, then review notes linked to what was said. Everything is processed locally.")
                    .foregroundStyle(.secondary).frame(maxWidth: 520, alignment: .leading).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                if readiness.requiredComplete || model.libraryRecovery != nil || !model.runtimeChecked {
                    HStack(spacing: Theme.Space.m) {
                        Button("New Meeting") { model.showNewMeeting = true }.buttonStyle(.borderedProminent).controlSize(.large)
                            .disabled(model.newMeetingBlockedReason != nil).help(model.newMeetingBlockedReason ?? "Start a new meeting")
                        SettingsLink { Text("Settings") }.controlSize(.large)
                    }
                    HStack(spacing: Theme.Space.l) { Label("Online or in person", systemImage: "person.2"); Label("No meeting bot", systemImage: "video.slash"); Label("Local only", systemImage: "lock.shield") }
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    setupCard(readiness)
                }

            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(Theme.Space.xxl + 8)
            .frame(maxWidth: .infinity)
        }
    }

    private func setupCard(_ readiness: SetupReadiness) -> some View {
        SectionCard("Finish setting up", subtitle: "Echo Voice needs a speech model before it can transcribe. It only takes a few steps.", systemImage: "checklist",
                    trailing: AnyView(StatusBadge(text: readiness.overall.title, tone: readiness.overall.tone))) {
            SetupChecklistView()
            HStack {
                Button("Continue Setup") { model.presentSetupGuide() }.buttonStyle(.borderedProminent).controlSize(.large)
                Button("Record Without Transcription") { model.showNewMeeting = true }.controlSize(.large)
                    .disabled(model.newMeetingBlockedReason != nil)
                    .help(model.newMeetingBlockedReason ?? "Audio is saved and transcription waits until a speech model is ready.")
            }
        }
    }

}
