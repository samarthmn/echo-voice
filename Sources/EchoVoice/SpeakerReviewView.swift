import SwiftUI
import EchoCore

struct SpeakerReviewView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var playbackModel: PlaybackModel
    @Environment(\.dismiss) private var dismiss
    let run: SpeakerGroupingRun
    init(run: SpeakerGroupingRun, playbackModel: PlaybackModel) {
        self.run = run
        self.playbackModel = playbackModel
    }
    @State private var previews: [String: [SpeakerPreview]] = [:]
    @State private var sampleIndices: [String: Int] = [:]
    @State private var names: [String: String] = [:]
    @State private var loading = true

    private var groupedSpeakers: [Speaker] {
        model.speakers.filter { speaker in run.turns.contains { $0.speakerID == speaker.id } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Review speakers").font(.title2.weight(.semibold))
                    Text("Names are labels you provide for this meeting, not verified identities.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { model.stopPlayback(); dismiss() }.keyboardShortcut(.defaultAction)
            }
            if run.partial {
                Text("These groups are limited to separate 30-minute sections. The same label in different sections may be different people.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if loading { ProgressView("Finding voice samples…") }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(groupedSpeakers) { speaker in
                        let samples = previews[speaker.id] ?? []
                        let index = min(sampleIndices[speaker.id] ?? 0, max(0, samples.count - 1))
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                TextField("Speaker name", text: Binding(
                                    get: { names[speaker.id] ?? speaker.label },
                                    set: { names[speaker.id] = $0 }
                                ))
                                Button("Save name") {
                                    model.renameSpeaker(speaker, label: names[speaker.id] ?? speaker.label)
                                }.disabled((names[speaker.id] ?? speaker.label).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                            if !samples.isEmpty {
                                HStack {
                                    Button(playbackModel.playing && model.playbackTrack == run.track
                                           && playbackModel.time >= samples[index].start
                                           && playbackModel.time < samples[index].end ? "Stop" : "Play voice") {
                                        if playbackModel.playing && model.playbackTrack == run.track
                                            && playbackModel.time >= samples[index].start
                                            && playbackModel.time < samples[index].end { model.stopPlayback() }
                                        else { model.playSpeakerPreview(samples[index], meetingID: run.meetingID) }
                                    }
                                    Button("Next sample") {
                                        model.stopPlayback()
                                        sampleIndices[speaker.id] = (index + 1) % samples.count
                                    }.disabled(samples.count < 2)
                                    Text("\(index + 1) of \(samples.count) · \(AppModel.timestamp(samples[index].start))")
                                        .font(.caption).foregroundStyle(.secondary)
                                    if samples[index].shortSample { Text("Short sample").font(.caption).foregroundStyle(.secondary) }
                                    if samples[index].overlapsAnotherSpeaker { Text("Overlapping voices").font(.caption).foregroundStyle(.secondary) }
                                }
                            } else {
                                Text("No usable voice sample is available for this speaker.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
        }
        .padding(24).frame(width: 620, height: 560)
        .task(id: run.id) {
            loading = true
            names = Dictionary(uniqueKeysWithValues: groupedSpeakers.map { ($0.id, $0.label) })
            do { previews = try await model.speakerPreviews(for: run) }
            catch { model.error = error.localizedDescription }
            loading = false
        }
        .onDisappear { model.stopPlayback() }
    }
}
