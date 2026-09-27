import SwiftUI
import EchoCore

private struct TranscriptAvailabilityView<Content: View>: View {
    @ObservedObject var list: TranscriptListModel
    let content: (Bool) -> Content
    var body: some View { content(list.rows.isEmpty) }
}

struct MeetingDetailView: View {
    @EnvironmentObject var model: AppModel
    let meeting: Meeting
    @ObservedObject var recordingSession: RecordingSessionModel
    @ObservedObject var playbackModel: PlaybackModel
    @Environment(\.openSettings) private var openSettings
    @State private var showRegenerate = false
    @State private var showSavedMoments = false
    @State private var showSpeakerReview = false
    @State private var regenerateModel = SpeechRecognitionModel.parakeet
    @State private var useVocabulary = true
    @State private var editingTitle = false
    @State private var title = ""
    @State private var editingNotes: MeetingNotes?
    @State private var notesVersionID: String?
    @State private var playbackTrack: AudioTrack? = nil
    private var isCurrent: Bool { model.recordingID == meeting.id }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                if model.pendingMeetingDeletions.contains(meeting.id) {
                    Banner(message: "This meeting has a deletion that needs recovery. Other meetings are available.", systemImage: "trash", tone: .attention) {
                        Button("Retry deletion recovery") { model.retryMeetingDeletions() }
                    }
                } else if model.recoveringAssetMeetings.contains(meeting.id) {
                    Banner(message: "Checking saved audio for this meeting…", systemImage: "externaldrive") {
                        ProgressView().controlSize(.small)
                    }
                } else if model.damagedAssetMeetings.contains(meeting.id) {
                    Banner(message: "Saved audio needs repair. This meeting is protected from recording and file changes until recovery succeeds.", systemImage: "externaldrive.badge.exclamationmark", tone: .attention) {
                        Button("Retry audio recovery") { model.retryAssetRecovery(meetingID: meeting.id) }
                    }
                }
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        HStack {
                            Text(meeting.title).font(Theme.Font.pageTitle).textSelection(.enabled)
                            Button { title = meeting.title; editingTitle = true } label: { Image(systemName: "pencil").font(.caption) }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Rename meeting").help("Rename meeting")
                        }
                        HStack(spacing: Theme.Space.m) {
                            Text(meeting.startedAt, format: .dateTime.month(.wide).day().hour().minute())
                            if let ended = meeting.endedAt { Text("·"); Text(AppModel.duration(ended.timeIntervalSince(meeting.startedAt))) }
                            Text("·")
                            Label(meeting.sourceName, systemImage: meeting.recordingMode == .inPerson ? "person.2" : "video")
                            StatusBadge(text: meeting.state.displayLabel, tone: meeting.state.tone)
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !isCurrent { processButton }
                }
                if isCurrent { recordingControls }
                else if model.pendingRedactionMeetings.contains(meeting.id) {
                    Banner(message: "A passage deletion is being recovered. Playback, export, and processing for this meeting are paused.", systemImage: "trash", tone: .attention) {
                        Button("Retry deletion") { model.retryPendingRedactions() }.disabled(model.redactionBusy)
                    }
                }
                else if meeting.state == .interrupted {
                    Banner(message: "Recording interrupted. Saved audio is available.", systemImage: "arrow.clockwise.circle") {
                        Button("Resume…") { model.showNewMeeting = true }.disabled(model.newMeetingBlockedReason != nil).help(model.newMeetingBlockedReason ?? "Continue recording into this meeting")
                        Button("Finalize") { model.processMeeting(meeting.id) }.disabled(processDisabledReason != nil).help(processDisabledReason ?? "Process the saved audio")
                    }
                }
                if model.processingID == meeting.id || isCurrent {
                    HStack(spacing: Theme.Space.s) {
                        if model.processingID == meeting.id { ProgressView().controlSize(.small) }
                        Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        Spacer()
                        let queued = model.jobStatus?.queuedCount ?? 0
                        if queued > 0 { StatusBadge(text: "\(queued) queued", tone: .progress) }
                    }
                }
                if !isCurrent, model.jobStatus?.failedDiarization == true {
                    Banner(message: model.health?.capabilities.diarize == true ? "Speaker grouping needs attention." : "Speaker grouping needs setup.", systemImage: "person.2.badge.gearshape") {
                        if model.health?.capabilities.diarize == true {
                            Button("Retry in 30-minute sections") { model.processMeeting(meeting.id, windowedSpeakers: true) }
                                .disabled(processDisabledReason != nil)
                                .help(processDisabledReason ?? "Speaker labels apply only within each section; the same label in different sections is not the same person.")
                        } else {
                            Button("Set Up Speaker Grouping") { openModels(.speakers) }
                        }
                    }
                }
                if !isCurrent, let reason = model.jobStatus?.firstFailure {
                    Banner(message: reason, systemImage: "exclamationmark.triangle", tone: .attention).textSelection(.enabled)
                }
                if !isCurrent {
                    HStack {
                        if model.groupingRuns.contains(where: { $0.transcriptVersionID == model.activeTranscriptID }) {
                            Button("Review speakers") { showSpeakerReview = true }
                        } else {
                            Menu("Group speakers for review") {
                                ForEach(model.availableSpeakerModels, id: \.id) { descriptor in
                                    Button(descriptor.displayName) { model.groupSpeakersForReview(modelID: descriptor.id) }
                                        .disabled(model.health?.models[descriptor.id]?.ready != true)
                                }
                                Divider()
                                Button("Set Up Speaker Grouping…") { openModels(.speakers) }
                            }
                                .disabled(model.processingID != nil)
                        }
                        Button("Regenerate transcript…") { showRegenerate = true }.disabled(!model.modelChangesAllowed)
                        Menu("Transcript history") {
                            ForEach(model.transcriptVersions.filter { $0.status == .ready }) { version in
                                Button(version.createdAt.formatted() + " · " + (model.catalog?.model(version.configuration?.speech.id ?? "")?.displayName ?? "Original")) { model.activateTranscript(version.id) }
                            }
                        }.disabled(model.playing || model.processingID != nil)
                        if let version = model.readyTranscriptID { Button("Use new transcript") { model.activateTranscript(version) }.disabled(model.playing || model.processingID != nil) }
                    }.font(.caption)
                }
                ModelSummaryView(title: isCurrent ? "Models selected for this meeting" : "Meeting models", configuration: displayConfiguration, usedRoles: usedModelRoles, actualNotes: displayedNotes?.model, actualSpeakers: displayedGrouping?.model, historical: !isCurrent)
                Picker("Review", selection: $model.selectedTab) {
                    Label("Transcript", systemImage: "waveform").tag("Transcript")
                    Label("Notes", systemImage: "note.text").tag("Notes")
                }.pickerStyle(.segmented).frame(maxWidth: 420)
            }.padding(Theme.Space.xl)
            Divider()
            if model.selectedTab == "Transcript" {
                transcript.allowsHitTesting(!model.pendingRedactionMeetings.contains(meeting.id) && !model.redactionBusy)
            } else if model.selectedTab == "Notes" {
                notes.allowsHitTesting(!model.pendingRedactionMeetings.contains(meeting.id) && !model.redactionBusy)
            } else { notes }
            Divider()
            HStack(spacing: 14) {
                Button { if model.playing { model.stopPlayback() } else { model.play(at: model.playbackTime, track: playbackTrack) } } label: { Image(systemName: model.playing ? "pause.fill" : "play.fill") }.buttonStyle(.bordered).accessibilityLabel(model.playing ? "Pause playback" : "Play saved audio")
                Button { model.play(at: max(0, model.playbackTime - 5), track: playbackTrack) } label: { Image(systemName: "gobackward.5") }.accessibilityLabel("Back five seconds")
                Text(AppModel.timestamp(model.playbackTime)).font(.callout.monospacedDigit())
                VStack(spacing: 0) {
                    Slider(value: Binding(get: { model.playbackTime }, set: { model.play(at: $0, track: playbackTrack) }), in: 0...max(1, meeting.endedAt?.timeIntervalSince(meeting.startedAt) ?? 1)).accessibilityLabel("Playback position")
                    GeometryReader { geometry in
                        ForEach(model.annotations.filter { $0.kind == .bookmark }) { item in
                            Button { model.play(at: item.startTime, track: item.track) } label: { Image(systemName: "bookmark.fill").font(.system(size: 8)) }
                                .buttonStyle(.plain).help(item.label ?? AppModel.timestamp(item.startTime))
                                .accessibilityLabel("Bookmark at " + AppModel.timestamp(item.startTime))
                                .offset(x: max(0, min(geometry.size.width - 8, geometry.size.width * item.startTime / max(1, meeting.endedAt?.timeIntervalSince(meeting.startedAt) ?? 1))))
                        }
                    }.frame(height: 9)
                }
                Button { model.play(at: model.playbackTime + 5, track: playbackTrack) } label: { Image(systemName: "goforward.5") }.accessibilityLabel("Forward five seconds")
                Picker("Speed", selection: $model.playbackRate) { ForEach([Float(0.75), 1, 1.25, 1.5, 2], id: \.self) { Text(String(format: "%g×", $0)).tag($0) } }.labelsHidden().frame(width: 70)
                Button { model.bookmark() } label: { Image(systemName: "bookmark") }.accessibilityLabel("Bookmark this moment")
                Picker("Track", selection: $playbackTrack) {
                    Text("Conversation").tag(AudioTrack?.none)
                    if model.availableTracks.contains(.remote) { Text("Meeting audio").tag(Optional(AudioTrack.remote)) }
                    if model.availableTracks.contains(.microphone) { Text(meeting.recordingMode.microphoneLabel).tag(Optional(AudioTrack.microphone)) }
                    if model.availableTracks.contains(.cleanMicrophone) { Text("Cleaned microphone").tag(Optional(AudioTrack.cleanMicrophone)) }
                }.labelsHidden().frame(width: 155).onChange(of: playbackTrack) { _, _ in model.stopPlayback(); model.play(at: model.playbackTime, track: playbackTrack) }
                Spacer()
                if !model.gaps.isEmpty { Label("\(model.gaps.count) timeline gaps", systemImage: "waveform.slash").font(.caption).foregroundStyle(.secondary).help(model.gaps.map { "\(AppModel.timestamp($0.startTime)) · \($0.reason)" }.joined(separator: "\n")) }
                Label("Stored locally", systemImage: "internaldrive").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 16).padding(.vertical, 12)
                .disabled(model.isRecording || model.redactionBusy || model.pendingRedactionMeetings.contains(meeting.id))
        }
        .sheet(isPresented: $showRegenerate) {
            let ready = model.isModelReady(regenerateModel.assetKey)
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                Text("Regenerate transcript").font(.title2.weight(.semibold))
                Text("Creates a new version from saved audio. Previous text, edits, and notes are retained.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Picker("Speech model", selection: $regenerateModel) {
                    ForEach(SpeechRecognitionModel.allCases, id: \.self) { Text($0.displayName + (model.isModelReady($0.assetKey) ? "" : " — not downloaded")).tag($0) }
                }
                Toggle("Use current vocabulary", isOn: $useVocabulary)
                if !ready {
                    Banner(message: "\(regenerateModel.displayName) must be downloaded first.", systemImage: "arrow.down.circle") {
                        Button("Set Up…") { showRegenerate = false; openModels(.speech) }.controlSize(.small)
                    }
                }
                HStack {
                    Button("Cancel") { showRegenerate = false }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Regenerate") { model.regenerateTranscript(speech: regenerateModel, useVocabulary: useVocabulary); showRegenerate = false }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!ready)
                }
            }.padding(Theme.Space.xl).frame(width: 480)
            .onAppear { regenerateModel = readyRegenerationModel }
        }
        .sheet(item: $editingNotes) { NotesEditorView(draft: $0).environmentObject(model) }
        .sheet(isPresented: $model.showInputsPanel) { RecordingInputsView().environmentObject(model) }
        .sheet(isPresented: $showSpeakerReview, onDismiss: { model.stopPlayback() }) {
            if let run = model.groupingRuns.first(where: { $0.transcriptVersionID == model.activeTranscriptID }) {
                SpeakerReviewView(run: run, playbackModel: playbackModel).environmentObject(model)
            }
        }
        .alert("Rename meeting", isPresented: $editingTitle) { TextField("Title", text: $title); Button("Cancel", role: .cancel) {}; Button("Save") { model.renameMeeting(title) } }
        .onChange(of: meeting.id) { _, _ in notesVersionID = nil; playbackTrack = nil }
        .background(ReplayEventMonitor(onScroll: { model.followPlayback = false }, onSpace: {
            guard !model.isRecording else { return }
            if model.playing { model.stopPlayback() } else { model.play(at: model.playbackTime, track: playbackTrack) }
        }))
    }

    private var speechReady: Bool { model.health?.canTranscribe(meeting.recognitionModel) == true }
    private var processDisabledReason: String? {
        if model.isRecording { return "Processing starts after the current recording stops." }
        if model.processingID != nil { return model.processingID == meeting.id ? "This meeting is processing." : "Another meeting is processing." }
        if model.setupBusy { return "Processing is available when the current download or setup finishes." }
        return nil
    }
    @ViewBuilder private var processButton: some View {
        if !speechReady && model.processingID != meeting.id {
            Button("Set Up \(meeting.recognitionModel.displayName)…") { openModels(.speech) }
                .help("This meeting's speech model must be downloaded before it can be transcribed. Saved audio is kept.")
        } else {
            Button(model.processingID == meeting.id ? "Processing…" : "Generate / Retry") { model.processMeeting(meeting.id) }
                .disabled(processDisabledReason != nil)
                .help(processDisabledReason ?? "Run any unfinished transcription, speaker grouping and notes")
        }
    }
    private func openModels(_ role: ModelRole) {
        model.settingsPage = .models; model.settingsModelRole = role; openSettings()
    }
    private var readyRegenerationModel: SpeechRecognitionModel {
        [meeting.recognitionModel, .parakeet, .whisper].first { model.isModelReady($0.assetKey) } ?? meeting.recognitionModel
    }

    private var displayedNotes: MeetingNotes? { model.notes.first(where: { $0.id == notesVersionID }) ?? model.latestNotes }
    private var displayedGrouping: SpeakerGroupingRun? { model.groupingRuns.first { $0.transcriptVersionID == model.activeTranscriptID } }
    private var displayConfiguration: ProcessingConfiguration? {
        isCurrent || model.activeTranscriptID == "legacy-" + meeting.id ? model.selectedConfiguration : model.transcriptVersions.first(where: { $0.id == model.activeTranscriptID })?.configuration
    }
    private var usedModelRoles: Set<ModelRole> {
        var roles = Set<ModelRole>()
        if model.transcriptList?.count ?? 0 > 0 { roles.insert(.speech) }
        if displayedNotes != nil { roles.insert(.notes) }
        if displayedGrouping != nil { roles.insert(.speakers) }
        return roles
    }

    private func notesModelName(_ selection: ModelSelection?) -> String {
        guard let selection else { return "Off" }
        if selection.provider == .ollama { return "Ollama · " + selection.id }
        return "Native · " + (model.catalog?.model(selection.id)?.displayName ?? selection.id)
    }

    private var recordingControls: some View {
        HStack(spacing: 18) {
            Circle().fill(model.isPaused ? .orange : .red).frame(width: 9, height: 9)
            Text(AppModel.timestamp(model.elapsed)).font(.title3.monospacedDigit())
            LevelMeter(name: meeting.recordingMode.microphoneLabel, level: model.microphoneLevel)
            if meeting.recordingMode == .online { LevelMeter(name: model.waitingForRemoteAudio ? "Meeting · waiting" : "Meeting", level: model.remoteLevel) }
            Spacer()
            if model.liveTranscriptionPolicy?.admitsLiveRecognition == true {
                Button("Stop live transcription") { Task { await model.stopLiveTranscription() } }
                    .help("Keep recording audio; transcribe the remaining speech after the meeting")
            } else if model.liveTranscriptionPolicy?.enabledAtStart == true {
                Text("Remaining transcript after meeting").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Transcript after meeting").font(.caption).foregroundStyle(.secondary)
            }
            Button { Task { await model.setMicrophoneMuted(!model.microphoneMuted) } } label: {
                Image(systemName: model.microphoneMuted ? "mic.slash.fill" : "mic.fill")
            }.help(model.microphoneMuted ? "Unmute microphone in Echo Voice" : "Mute microphone in Echo Voice")
                .accessibilityLabel(model.microphoneMuted ? "Unmute microphone" : "Mute microphone")
            Button("Inputs…") { model.refreshSources(); model.showInputsPanel = true }
            Button { Task { await model.togglePause() } } label: { Image(systemName: model.isPaused ? "play.fill" : "pause.fill") }.help(model.isPaused ? "Resume" : "Pause").accessibilityLabel(model.isPaused ? "Resume recording" : "Pause recording")
            Button("Stop") { Task { await model.stopRecording() } }.buttonStyle(.borderedProminent).tint(.red).accessibilityLabel("Stop recording")
        }.padding(Theme.Space.l)
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.Radius.l))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.l).strokeBorder((model.isPaused ? Color.orange : Color.red).opacity(0.35)))
    }

    private var transcript: some View {
        Group {
            if let list = model.transcriptList {
                TranscriptAvailabilityView(list: list) { isEmpty in transcriptContent(isEmpty: isEmpty) }
            }
        }
    }

    private func transcriptContent(isEmpty: Bool) -> some View {
        Group {
            if isEmpty {
                if isCurrent {
                    EmptyStateView(title: "Listening for the conversation", systemImage: "waveform", message: speechReady ? "Audio is saved continuously. Text appears as local recognition finishes each window." : "Audio is saved continuously. Transcription starts once \(meeting.recognitionModel.displayName) is downloaded.")
                } else if !speechReady {
                    EmptyStateView(title: "Transcript waiting for setup", systemImage: "arrow.down.circle", message: "Download \(meeting.recognitionModel.displayName), then generate the transcript. Saved audio is kept.") {
                        Button("Set Up Speech Model") { openModels(.speech) }.buttonStyle(.borderedProminent)
                    }
                } else {
                    EmptyStateView(title: "No transcript yet", systemImage: "waveform", message: "Generate the transcript from the saved audio.") {
                        Button("Generate Transcript") { model.processMeeting(meeting.id) }.buttonStyle(.borderedProminent)
                            .disabled(processDisabledReason != nil).help(processDisabledReason ?? "")
                    }
                }
            } else {
                if let list = model.transcriptList {
                    VStack(spacing: 8) {
                        if list.rows.contains(where: \.isProvisional) { Label("Live text is provisional until its audio window is finalized.", systemImage: "pencil.line").font(.caption).foregroundStyle(.secondary) }
                        HStack {
                            Toggle("Show only highlights", isOn: $model.showOnlyHighlights).toggleStyle(.switch).controlSize(.small)
                            Spacer()
                            if !model.followPlayback { Button("Follow playback") { model.followPlayback = true } }
                            Button("Saved moments") { showSavedMoments = true }
                                .popover(isPresented: $showSavedMoments) { SavedMomentsView().environmentObject(model) }
                        }.padding(.horizontal, 16)
                        if model.showOnlyHighlights && model.playing && !model.annotations.contains(where: { $0.kind == .highlight && model.playbackTime >= $0.startTime && model.playbackTime < ($0.endTime ?? $0.startTime) }) {
                            HStack { Text("Playing outside saved highlights"); Button("Show full transcript") { model.showOnlyHighlights = false } }.font(.caption)
                        }
                        TranscriptTableView(list: list, model: model, playbackModel: playbackModel, highlightsOnly: model.showOnlyHighlights,
                                            highlightedIDs: Set(model.annotations.filter { $0.kind == .highlight }.compactMap(\.segmentID)),
                                            activePassageID: activePassageID)
                        if !model.gaps.isEmpty {
                            ScrollView(.horizontal) {
                                HStack { ForEach(model.gaps) { gap in Label("\(AppModel.timestamp(gap.startTime)) · \(gap.reason)", systemImage: "waveform.slash").font(.caption).foregroundStyle(.orange) } }
                            }.frame(height: 28).padding(.horizontal, 16)
                        }
                    }.padding(.vertical, 8)
                }
            }
        }
    }
    private var activePassageID: String? { model.activePassageID }

    private var notes: some View {
        Group {
            if let notes = model.notes.first(where: { $0.id == notesVersionID }) ?? model.latestNotes {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        HStack {
                            if model.notes.count > 1 {
                                Picker("Version", selection: $notesVersionID) {
                                    Text("Latest version").tag(String?.none)
                                    ForEach(model.notes) { version in Text(version.createdAt.formatted(date: .abbreviated, time: .shortened) + (version.isEdited ? " · Edited" : " · Generated")).tag(Optional(version.id)) }
                                }.frame(maxWidth: 290)
                            }
                            if notes.isEdited { Label("Edited by you", systemImage: "pencil").font(.caption).foregroundStyle(.secondary) }
                            if notes.isPartial { Label("Partial draft", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange) }
                            if notes.transcriptRevision != meeting.transcriptRevision { Label("Transcript changed · regenerate to update", systemImage: "arrow.clockwise").font(.caption).foregroundStyle(.orange) }
                            Spacer(); Button("Edit Notes") { editingNotes = notes }
                        }
                        if let used = notes.model { Text("Generated with " + notesModelName(used)).font(.caption).foregroundStyle(.secondary) }
                        noteSection("Summary", icon: "text.alignleft", items: notes.summary)
                        noteSection("Decisions", icon: "checkmark.seal", items: notes.decisions)
                        noteSection("Action items", icon: "checklist", items: notes.actionItems)
                        if model.notes.count > 1 { Text("\(model.notes.count) versions retained. Regeneration preserves earlier drafts and your edits.").font(.caption).foregroundStyle(.secondary) }
                    }.padding(28)
                }
            } else if model.defaultNotesSelection() == nil && meeting.state == .ready {
                EmptyStateView(title: "Meeting notes are off", systemImage: "note.text", message: "Turn on a notes model to draft summaries, decisions, and action items linked to the transcript.") {
                    Button("Set Up Notes") { openModels(.notes) }
                }
            } else {
                EmptyStateView(title: "Notes follow the conversation", systemImage: "note.text", message: "After recording, local models draft a summary, decisions, and action items linked to the transcript.")
            }
        }
    }
    private func noteSection(_ title: String, icon: String, items: [NoteItem]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: icon).font(.title3.bold())
            if items.isEmpty { Text("No supported items identified.").foregroundStyle(.secondary).font(.callout) }
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 9) {
                    if item.evidenceRemoved == true { Text("Evidence removed").font(.caption).foregroundStyle(.secondary) }
                    Text(item.text).textSelection(.enabled).lineSpacing(4)
                    HStack {
                        if let owner = item.owner { Label(owner, systemImage: "person").font(.caption).foregroundStyle(.secondary) }
                        if let due = item.dueDate { Label(due, systemImage: "calendar").font(.caption).foregroundStyle(.secondary) }
                        ForEach(item.evidenceIDs, id: \.self) { id in Button { model.showEvidence(id) } label: { Label(evidenceLabel(id), systemImage: "link").font(.caption) }.buttonStyle(.borderless) }
                    }
                }.padding(Theme.Space.l).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.Radius.m))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m).strokeBorder(Theme.cardStroke))
            }
        }
    }
    private func evidenceLabel(_ id: String) -> String { model.transcriptList?.rows.first(where: { $0.id == id }).map { AppModel.timestamp($0.startTime) } ?? "Earlier evidence" }


}

struct TranscriptRow: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var playbackModel: PlaybackModel
    let segment: TranscriptSegment
    @State private var editing = false
    @State private var deletionPreview: RedactionPreview?
    @State private var text = ""
    @State private var renaming = false
    @State private var speakerName = ""
    @State private var selectedRange = NSRange(location: 0, length: 0)
    private var speaker: Speaker? { model.speakers.first { $0.id == segment.speakerID } }
    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            Button(AppModel.timestamp(segment.startTime)) { model.play(at: segment.startTime, track: segment.track) }.font(.caption.monospacedDigit()).buttonStyle(.plain).foregroundStyle(Theme.accent).accessibilityLabel("Play from " + AppModel.timestamp(segment.startTime)).frame(width: 62, alignment: .leading).padding(.top, 3)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(speaker?.label ?? (model.selectedMeeting?.recordingMode == .inPerson ? "Speaker unknown" : segment.track == .remote ? "Remote speaker" : "You")).font(.callout.weight(.semibold))
                    if segment.isUncertain { Text("Review recognition").font(.caption2).foregroundStyle(.orange) }
                    if (segment.track == .remote || model.selectedMeeting?.recordingMode == .inPerson) && speaker?.isVerified != true { Text("Speaker unreviewed").font(.caption2).foregroundStyle(.secondary) }
                    if segment.isProvisional { Text("Live").font(.caption2).foregroundStyle(.secondary) }
                    if segment.isEdited { Image(systemName: "pencil").font(.caption2).foregroundStyle(.secondary).help("Corrected by you") }
                    Spacer()
                    if !segment.isProvisional {
                        Button { text = segment.text; editing = true } label: { Image(systemName: "pencil") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).help("Correct transcript")
                            .accessibilityLabel("Correct transcript")
                        Button {
                            Task { deletionPreview = await model.previewPassageDeletion(segment) }
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .disabled(model.isRecording || model.redactionBusy)
                            .help(model.isRecording ? "Stop recording before permanently deleting a passage" : "Permanently delete passage and audio")
                            .accessibilityLabel("Delete passage and audio")
                    }
                }
                TranscriptTextView(segment: segment, time: model.playing && model.isAudible(segment.track) ? model.playbackTime : nil, highlights: model.annotations.filter { $0.segmentID == segment.id }.compactMap { item in guard let location = item.location, let length = item.length else { return nil }; return NSRange(location: location, length: length) }, play: { model.play(at: $0, track: model.playbackTrack) }, highlight: { model.highlight(segment, range: $0) }, selectionChanged: { selectedRange = $0; if $0.length > 0 { model.followPlayback = false } })
                if selectedRange.length > 0, NSMaxRange(selectedRange) <= (segment.text as NSString).length {
                    HStack {
                        Button("Play from here") { let anchor = segment.words?.first { NSIntersectionRange($0.range, selectedRange).length > 0 }?.start ?? segment.startTime; model.play(at: anchor, track: model.playbackTrack) }
                        Button("Highlight / remove") { model.highlight(segment, range: selectedRange) }
                        Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString((segment.text as NSString).substring(with: selectedRange), forType: .string) }
                    }.font(.caption).buttonStyle(.bordered)
                }
                if let run = model.groupingRuns.first(where: { $0.transcriptVersionID == model.activeTranscriptID && $0.track == segment.track }) {
                    let spans = model.speakerSpans(for: segment, run: run)
                    if spans.count > 1 {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Speaker changes").font(.caption.weight(.medium))
                            ForEach(Array(spans.enumerated()), id: \.offset) { _, span in
                                HStack(alignment: .top) {
                                    Button(AppModel.timestamp(span.start)) { model.play(at: span.start, track: segment.track) }.monospacedDigit()
                                    let names = span.speakerIDs.map { id in model.speakers.first(where: { $0.id == id })?.label ?? "Speaker unknown" }
                                    Text((names.isEmpty ? "Speaker unknown" : names.joined(separator: " + ")) + (span.uncertain ? " · Uncertain" : ""))
                                    Text((segment.text as NSString).substring(with: span.range)).foregroundStyle(.secondary)
                                }.font(.caption)
                            }
                        }.font(.caption)
                    } else if spans.isEmpty || spans.contains(where: \.uncertain) {
                        Text("Speaker attribution uncertain").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if segment.words?.contains(where: { $0.source == .tokenEmission }) == true { Text("Approximate word timing").font(.caption2).foregroundStyle(.secondary) }
            }
        }.padding(Theme.Space.m).background(model.playing && model.isAudible(segment.track) && model.playbackTime >= segment.startTime && model.playbackTime < segment.endTime ? Theme.accent.opacity(0.14) : Theme.subtleFill, in: RoundedRectangle(cornerRadius: Theme.Radius.m))
            .contextMenu { Button("Bookmark passage") { model.bookmark(at: segment.startTime) }; Button("Highlight passage") { model.highlight(segment, range: NSRange(location: 0, length: (segment.text as NSString).length)) }; if speaker != nil { Button("Rename Speaker") { speakerName = speaker?.label ?? ""; renaming = true } } }
            .sheet(isPresented: $editing) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Correct transcript").font(.headline)
                    TextEditor(text: $text).frame(width: 480, height: 160)
                    HStack { Button("Cancel") { editing = false }; Spacer(); Button("Save") { model.editSegment(segment, text: text); editing = false }.buttonStyle(.borderedProminent) }
                }.padding(24)
            }
            .alert("Rename speaker", isPresented: $renaming) { TextField("Display name", text: $speakerName); Button("Cancel", role: .cancel) {}; Button("Save") { if let speaker { model.renameSpeaker(speaker, label: speakerName) } } } message: { Text("This is a display label, not a verified identity.") }
            .alert("Delete passage and audio?", isPresented: Binding(
                get: { deletionPreview != nil }, set: { if !$0 { deletionPreview = nil } }
            )) {
                Button("Cancel", role: .cancel) { deletionPreview = nil }
                Button("Delete passage and audio", role: .destructive) {
                    if let preview = deletionPreview { Task { await model.deletePassageAndAudio(preview) } }
                    deletionPreview = nil
                }
            } message: {
                if let preview = deletionPreview {
                    Text("\(AppModel.timestamp(preview.start))–\(AppModel.timestamp(preview.end)) across \(preview.affectedTracks.count) recorded track(s), including simultaneous speech. \(preview.activePassages) current and \(preview.historicalPassages) historical passage(s), \(preview.annotations) saved mark(s), and \(preview.noteItems) note item(s) are affected. Passages include: \(preview.affectedPassageExcerpts.joined(separator: " | ")). \(preview.whollyRemovedOverlappingPassages) overlapping passage(s) lack reliable timing and will be removed in full. This cannot be undone. Existing exports and external backups remain.")
                }
            }
    }
}

private struct NotesEditorView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State var draft: MeetingNotes
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit notes").font(.title2.bold())
            Text("A new version will be saved. Existing evidence links are retained.").foregroundStyle(.secondary)
            Form {
                Section("Summary") { ForEach($draft.summary) { $item in TextField("Summary", text: $item.text, axis: .vertical) } }
                Section("Decisions") { ForEach($draft.decisions) { $item in TextField("Decision", text: $item.text, axis: .vertical) } }
                Section("Action items") {
                    ForEach($draft.actionItems) { $item in
                        VStack(alignment: .leading) {
                            TextField("Action", text: $item.text, axis: .vertical)
                            HStack {
                                TextField("Owner (optional)", text: Binding(get: { item.owner ?? "" }, set: { item.owner = $0.isEmpty ? nil : $0 }))
                                TextField("Due date (optional)", text: Binding(get: { item.dueDate ?? "" }, set: { item.dueDate = $0.isEmpty ? nil : $0 }))
                            }
                        }
                    }
                }
            }.formStyle(.grouped)
            HStack { Button("Cancel") { dismiss() }; Spacer(); Button("Save Version") { model.saveNotes(draft); dismiss() }.buttonStyle(.borderedProminent) }
        }.padding(24).frame(width: 620, height: 530)
    }
}

private struct SavedMomentsView: View {
    @EnvironmentObject var model: AppModel
    @State private var editing: TranscriptAnnotation?
    @State private var label = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Saved moments").font(.headline)
            if model.annotations.isEmpty { Text("Highlight transcript text or bookmark a moment in the player.").foregroundStyle(.secondary) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.annotations) { item in
                        HStack {
                            Button { model.play(at: item.startTime, track: item.track) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Label(AppModel.timestamp(item.startTime) + " · " + (item.label ?? item.quote ?? "Bookmark"), systemImage: item.kind == .bookmark ? "bookmark" : "highlighter")
                                    if let version = item.transcriptVersionID, version != model.activeTranscriptID { Text("Saved from an earlier transcript").font(.caption).foregroundStyle(.secondary) }
                                }
                            }.buttonStyle(.plain)
                            Spacer()
                            Button { editing = item; label = item.label ?? "" } label: { Image(systemName: "pencil") }.accessibilityLabel("Edit saved label")
                            Button { model.removeAnnotation(item) } label: { Image(systemName: "trash") }.accessibilityLabel("Remove saved moment")
                        }
                    }
                }
            }
        }.padding(16).frame(width: 380, height: 300)
        .alert("Saved moment label", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("Label", text: $label)
            Button("Cancel", role: .cancel) { editing = nil }
            Button("Save") { if var item = editing { item.label = label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : String(label.prefix(120)); model.saveAnnotation(item) }; editing = nil }
        }
    }
}
