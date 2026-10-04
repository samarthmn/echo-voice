import SwiftUI
import EchoCore

struct PlaybackBar: View {
    @EnvironmentObject private var model: AppModel
    let meeting: Meeting
    @ObservedObject var playback: PlaybackModel
    @Binding var track: AudioTrack?
    private var duration: Double { max(1, meeting.endedAt?.timeIntervalSince(meeting.startedAt) ?? 1) }
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button { if playback.playing { model.stopPlayback() } else { seek(playback.time) } } label: {
                    Image(systemName: playback.playing ? "pause.fill" : "play.fill")
                }.accessibilityLabel(playback.playing ? "Pause playback" : "Play saved audio")
                Button { seek(max(0, playback.time - 5)) } label: { Image(systemName: "gobackward.5") }.accessibilityLabel("Back five seconds")
                Text(AppModel.timestamp(playback.time)).monospacedDigit().font(.caption)
                Slider(value: Binding(get: { min(duration, playback.time) }, set: { seek($0) }), in: 0...duration)
                    .accessibilityLabel("Playback position")
                Text(AppModel.timestamp(duration)).monospacedDigit().font(.caption).foregroundStyle(.secondary)
                Button { seek(min(duration, playback.time + 5)) } label: { Image(systemName: "goforward.5") }.accessibilityLabel("Forward five seconds")
                Button { model.bookmark() } label: { Image(systemName: "bookmark") }.accessibilityLabel("Bookmark this moment")
            }
            HStack {
                Picker("Audio", selection: $track) {
                    Text("Conversation").tag(AudioTrack?.none)
                    if model.availableTracks.contains(.remote) { Text("Meeting audio").tag(Optional(AudioTrack.remote)) }
                    if model.availableTracks.contains(.microphone) { Text(meeting.recordingMode.microphoneLabel).tag(Optional(AudioTrack.microphone)) }
                    if model.availableTracks.contains(.cleanMicrophone) { Text("Cleaned microphone").tag(Optional(AudioTrack.cleanMicrophone)) }
                }.frame(maxWidth: 250).onChange(of: track) { _, _ in
                    let wasPlaying = playback.playing
                    model.stopPlayback(); model.playbackTrack = track
                    if wasPlaying { seek(playback.time) }
                }
                Spacer()
                Picker("Speed", selection: $model.playbackRate) {
                    ForEach([Float(0.75), 1, 1.25, 1.5, 2], id: \.self) { rate in Text(String(format: "%g×", rate)).tag(rate) }
                }.frame(width: 110)
            }.font(.caption)
        }
        .padding(.horizontal, 16).padding(.vertical, 12).background(.bar)
        .disabled(model.isRecording || model.redactionBusy || model.pendingRedactionMeetings.contains(meeting.id))
    }
    private func seek(_ time: Double) { model.play(at: time, track: track, meetingID: meeting.id) }
}
