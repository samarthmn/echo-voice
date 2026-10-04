import SwiftUI
import EchoCore

struct RecordingBar: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: RecordingSessionModel
    private var meeting: Meeting? { model.meetings.first { $0.id == model.recordingID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { recordingSummary; Spacer(minLength: 8); controls }
                VStack(alignment: .leading, spacing: 10) {
                    recordingSummary
                    HStack { Spacer(); controls }
                }
            }
            if !model.recording.message.isEmpty { Text(model.recording.message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            ViewThatFits(in: .horizontal) {
                HStack { sourceLevels; Spacer(); transcriptionControl }
                VStack(alignment: .leading, spacing: 8) { sourceLevels; transcriptionControl }
            }
        }
        .padding(16).background(.bar)
        .accessibilityElement(children: .contain).accessibilityLabel("Active recording")
    }
    private var recordingSummary: some View {
        HStack(spacing: 12) {
            Label(model.isPaused ? "Paused" : "Recording", systemImage: model.isPaused ? "pause.circle.fill" : "record.circle.fill")
                .foregroundStyle(model.isPaused ? .orange : .red).font(.callout.weight(.semibold))
            Text(AppModel.timestamp(session.elapsed)).monospacedDigit()
            Button(meeting?.title ?? "Current meeting") { model.selectedID = model.recordingID; model.selectedTab = .transcript }
                .buttonStyle(.plain).lineLimit(1).help("Open the current recording")
        }
    }
    private var controls: some View {
        HStack(spacing: 8) {
            Button { Task { await model.setMicrophoneMuted(!model.microphoneMuted) } } label: {
                Label(model.microphoneMuted ? "Unmute" : "Mute", systemImage: model.microphoneMuted ? "mic.slash" : "mic")
            }.accessibilityLabel(model.microphoneMuted ? "Unmute microphone in Echo Voice" : "Mute microphone in Echo Voice")
                .disabled(model.recordingMicrophoneUID == nil)
            Button("Inputs…") { model.showInputsPanel = true }.disabled(model.changingRecording)
            Button(model.isPaused ? "Resume" : "Pause", systemImage: model.isPaused ? "play.fill" : "pause.fill") {
                Task { await model.togglePause() }
            }.disabled(model.changingRecording)
            Button("Stop", systemImage: "stop.fill") { Task { await model.stopRecording() } }
                .buttonStyle(.borderedProminent).tint(.red).accessibilityIdentifier("stop-recording")
        }.fixedSize()
    }
    private var sourceLevels: some View {
        HStack(spacing: 14) {
            if model.recordingMicrophoneUID != nil {
                LevelMeter(name: model.microphoneMuted ? "Microphone muted" : "Microphone", level: session.microphoneLevel)
            } else {
                Label("No microphone selected", systemImage: "mic.slash").font(.caption).foregroundStyle(.secondary)
            }
            if meeting?.recordingMode == .online {
                LevelMeter(name: model.waitingForRemoteAudio ? "App audio · waiting" : "App audio", level: session.remoteLevel)
            }
        }
    }
    @ViewBuilder private var transcriptionControl: some View {
        if model.liveTranscriptionPolicy?.admitsLiveRecognition == true {
            Menu("Live transcript on") {
                Button("Stop Live Transcription") { Task { await model.stopLiveTranscription() } }
            }.menuStyle(.borderlessButton).fixedSize().font(.caption)
        } else {
            Label("Transcript after recording", systemImage: "text.bubble").font(.caption).foregroundStyle(.secondary)
        }
    }
}
