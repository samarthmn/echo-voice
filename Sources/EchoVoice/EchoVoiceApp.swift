import SwiftUI
import AppKit

@main
struct EchoVoiceApp: App {
    @NSApplicationDelegateAdaptor(EchoAppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Echo Voice", id: "main") {
            ContentView().environmentObject(model)
                .frame(minWidth: 960, minHeight: 640)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 1180, height: 780)
        .commands { EchoCommands(model: model) }
        Settings { SettingsView().environmentObject(model).frame(minWidth: 780, minHeight: 580) }
        MenuBarExtra("Echo Voice", systemImage: model.isRecording ? "record.circle.fill" : "waveform") {
            EchoMenuView(recordingSession: model.recordingSession).environmentObject(model)
        }
    }
}

private struct EchoCommands: Commands {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Meeting") { openWindow(id: "main"); model.showNewMeeting = true }
                .keyboardShortcut("n").disabled(model.newMeetingBlockedReason != nil || model.showOnboarding)
        }
        CommandMenu("Recording") {
            if model.isRecording && model.liveTranscriptionPolicy?.admitsLiveRecognition == true {
                Button("Stop Live Transcription") { Task { await model.stopLiveTranscription() } }
            }
            Button(model.microphoneMuted ? "Unmute Microphone" : "Mute Microphone") { Task { await model.setMicrophoneMuted(!model.microphoneMuted) } }
                .disabled(!model.isRecording)
            Button("Recording Inputs…") { openWindow(id: "main"); model.refreshSources(); model.showInputsPanel = true }
                .disabled(!model.isRecording)
            Button(model.isPaused ? "Resume Recording" : "Pause Recording") { Task { await model.togglePause() } }
                .keyboardShortcut("p", modifiers: [.command, .shift]).disabled(!model.isRecording)
            Button("Stop Recording") { Task { await model.stopRecording() } }
                .keyboardShortcut(".", modifiers: [.command]).disabled(!model.isRecording)
        }
        CommandGroup(replacing: .help) {
            Button("Setup Guide…") { openWindow(id: "main"); model.presentSetupGuide() }
                .disabled(!model.canPresentSetupGuide)
        }
    }
}

private struct EchoMenuView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var recordingSession: RecordingSessionModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(model.isRecording ? "Recording · \(AppModel.timestamp(recordingSession.elapsed))" : "Echo Voice · On this Mac")
        if !model.isRecording { Text(model.readiness.overall.title) }
        if model.isRecording {
            if model.liveTranscriptionPolicy?.admitsLiveRecognition == true {
                Button("Stop live transcription") { Task { await model.stopLiveTranscription() } }
            } else if model.liveTranscriptionPolicy?.enabledAtStart == true {
                Text("Transcript after recording")
            } else {
                Text("Transcript after meeting")
            }
            Button(model.microphoneMuted ? "Unmute Microphone" : "Mute Microphone") { Task { await model.setMicrophoneMuted(!model.microphoneMuted) } }
            Button("Inputs…") { showMainWindow(); model.refreshSources(); model.showInputsPanel = true }
            Button(model.isPaused ? "Resume" : "Pause") { Task { await model.togglePause() } }
            Button("Stop and Process") { Task { await model.stopRecording() } }
        } else {
            Button("New Meeting") { showMainWindow(); model.showNewMeeting = true }
                .disabled(model.newMeetingBlockedReason != nil || model.showOnboarding)
            if !model.readiness.requiredComplete || model.readiness.overall == .permissionNeeded {
                Button("Continue Setup…") { showMainWindow(); model.presentSetupGuide() }
                    .disabled(!model.canPresentSetupGuide)
            }
        }
        Divider()
        Button("Show Echo Voice") { showMainWindow() }
        SettingsLink()
        Button("Quit Echo Voice") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
    private func showMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

final class EchoAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil) }
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard !model.changingRecording, !model.importingLibrary else { return .terminateCancel }
        if model.isRecording {
            let alert = NSAlert()
            alert.messageText = "Stop recording and quit?"
            alert.informativeText = "Saved audio will be retained. You can finish transcription and notes when you reopen Echo Voice."
            alert.addButton(withTitle: "Stop and Quit"); alert.addButton(withTitle: "Keep Recording")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
        Task { @MainActor in await model.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
