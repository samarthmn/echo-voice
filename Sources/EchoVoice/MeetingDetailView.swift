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
    let playbackModel: PlaybackModel
    @Environment(\.openSettings) private var openSettings
    @State private var showRegenerate = false
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
            header
            meetingStatus
            Divider()
            Group {
                if model.selectedTab == .transcript { transcript }
                else { notes }
            }
            .allowsHitTesting(!model.pendingRedactionMeetings.contains(meeting.id) && !model.redactionBusy)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !isCurrent {
                Divider()
                PlaybackBar(meeting: meeting, playback: playbackModel, track: $playbackTrack)
            }
        }
        .inspector(isPresented: Binding(get: { model.workspace.inspectorVisible }, set: { model.workspace.inspectorVisible = $0 })) {
            inspector.inspectorColumnWidth(min: 270, ideal: 300, max: 360)
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
                    Button("Regenerate") { model.regenerateTranscript(speech: regenerateModel, useVocabulary: useVocabulary, meetingID: meeting.id); showRegenerate = false }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!ready)
                }
            }.padding(Theme.Space.xl).frame(width: 480)
            .onAppear { regenerateModel = readyRegenerationModel }
        }
        .sheet(item: $editingNotes) { NotesEditorView(draft: $0).environmentObject(model) }
        .sheet(isPresented: $showSpeakerReview, onDismiss: { model.stopPlayback() }) {
            if let run = model.groupingRuns.first(where: { $0.transcriptVersionID == model.activeTranscriptID }) {
                SpeakerReviewView(run: run, playbackModel: playbackModel).environmentObject(model)
            }
        }
        .alert("Rename meeting", isPresented: $editingTitle) { TextField("Title", text: $title); Button("Cancel", role: .cancel) {}; Button("Save") { model.renameMeeting(title, meetingID: meeting.id) } }
        .onChange(of: meeting.id) { _, _ in notesVersionID = nil; playbackTrack = nil }
        .background(ReplayEventMonitor(onScroll: { model.followPlayback = false }, onSpace: {
            guard !model.isRecording else { return }
            if model.playing { model.stopPlayback() } else { model.play(at: model.playbackTime, track: playbackTrack) }
        }))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(meeting.title).font(.title2.weight(.semibold)).lineLimit(2)
                        Button { title = meeting.title; editingTitle = true } label: { Image(systemName: "pencil") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Rename meeting")
                    }
                    Text(meeting.startedAt.formatted(date: .abbreviated, time: .shortened) + " · " + meeting.sourceName)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                StatusBadge(text: meeting.state.displayLabel, tone: meeting.state.tone)
            }
            HStack {
                Picker("Review", selection: $model.selectedTab) {
                    ForEach(ReviewTab.allCases) { tab in Text(tab.rawValue).tag(tab) }
                }.pickerStyle(.segmented).frame(width: 230).accessibilityIdentifier("review-tabs")
                Spacer()
                if !isCurrent {
                    Menu("Review Tools") {
                        Button("Review Speakers…") { showSpeakerReview = true }
                            .disabled(displayedGrouping == nil)
                        Menu("Group Speakers") {
                            ForEach(model.availableSpeakerModels) { descriptor in
                                Button(descriptor.displayName) { model.groupSpeakersForReview(modelID: descriptor.id) }
                                    .disabled(!model.isModelReady(descriptor.id) || !model.modelChangesAllowed)
                            }
                            Button("Set Up Speaker Grouping…") { openModels(.speakers) }
                        }
                        Button("Regenerate Transcript…") { showRegenerate = true }.disabled(!model.modelChangesAllowed)
                        Button("Retry Unfinished Processing") { model.processMeeting(meeting.id) }
                            .disabled(processDisabledReason != nil)
                        Button("Meeting Details") { model.workspace.inspectorVisible = true }
                    }.fixedSize()
                }
            }
        }.padding(20)
    }

    @ViewBuilder private var meetingStatus: some View {
        if model.pendingMeetingDeletions.contains(meeting.id) {
            Banner(message: "Meeting deletion needs recovery.", tone: .attention) {
                Button("Retry") { model.retryMeetingDeletions() }
            }.padding([.horizontal, .bottom], 16)
        } else if model.damagedAssetMeetings.contains(meeting.id) {
            Banner(message: "Saved audio needs repair.", tone: .attention) {
                Button("Repair Audio") { model.retryAssetRecovery(meetingID: meeting.id) }
            }.padding([.horizontal, .bottom], 16)
        } else if model.pendingRedactionMeetings.contains(meeting.id) {
            Banner(message: "Passage deletion needs recovery. Playback and export are paused.", tone: .attention) {
                Button("Retry") { model.retryPendingRedactions() }.disabled(model.redactionBusy)
            }.padding([.horizontal, .bottom], 16)
        } else if meeting.state == .interrupted {
            Banner(message: "Recording was interrupted. Saved audio is retained.", tone: .attention) {
                Button("Resume…") { model.resumeMeeting(meeting.id) }.disabled(model.newMeetingBlockedReason != nil)
                Button("Process Audio") { model.processMeeting(meeting.id) }.disabled(processDisabledReason != nil)
            }.padding([.horizontal, .bottom], 16)
        } else if let event = model.processingEvents[meeting.id], event.stage != .ready {
            HStack(spacing: 8) {
                if model.processingID == meeting.id { ProgressView().controlSize(.small) }
                Text(event.message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                if event.stage == .needsAttention { Button("Retry") { model.processMeeting(meeting.id) }.controlSize(.small) }
            }.padding([.horizontal, .bottom], 16)
        }
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Meeting Details").font(.headline)
                ModelSummaryView(title: "Models", configuration: displayConfiguration, usedRoles: usedModelRoles,
                                 actualNotes: displayedNotes?.model, actualSpeakers: displayedGrouping?.model, historical: !isCurrent)
                Divider()
                Text("Processing").font(.headline)
                if let failure = model.jobStatus?.firstFailure { Text(failure).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                if model.recoveringAssetMeetings.contains(meeting.id) { Label("Checking saved audio…", systemImage: "externaldrive") }
                if !isCurrent { processButton }
                if model.jobStatus?.failedDiarization == true {
                    Button("Retry Speakers in 30-minute Sections") { model.processMeeting(meeting.id, windowedSpeakers: true) }
                        .disabled(processDisabledReason != nil)
                    Text("Speaker labels apply within each section.").font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                Text("Transcript History").font(.headline)
                ForEach(model.transcriptVersions.filter { $0.status == .ready }) { version in
                    Button {
                        model.activateTranscript(version.id, meetingID: meeting.id)
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(version.createdAt.formatted(date: .abbreviated, time: .shortened))
                                Text(model.catalog?.model(version.configuration?.speech.id ?? "")?.displayName ?? "Original").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if version.id == model.activeTranscriptID { Image(systemName: "checkmark") }
                        }
                    }.buttonStyle(.plain).disabled(model.playing || model.isRecording || model.processingID != nil)
                }
                if let id = model.readyTranscriptID {
                    Button("Use New Transcript") { model.activateTranscript(id, meetingID: meeting.id) }
                        .disabled(model.playing || model.processingID != nil || model.isRecording)
                }
                Divider()
                SavedMomentsView()
            }.padding(16)
        }
    }

    private var speechReady: Bool { model.health?.canTranscribe(meeting.recognitionModel) == true }
    private var processDisabledReason: String? {
        if model.processingID == meeting.id { return "This meeting is processing." }
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
                            Button("Saved moments") { model.workspace.inspectorVisible = true }
                        }.padding(.horizontal, 16)
                        if model.showOnlyHighlights && model.playing && !model.annotations.contains(where: { $0.kind == .highlight && model.playbackTime >= $0.startTime && model.playbackTime < ($0.endTime ?? $0.startTime) }) {
                            HStack { Text("Playing outside saved highlights"); Button("Show full transcript") { model.showOnlyHighlights = false } }.font(.caption)
                        }
                        TranscriptTableView(list: list, model: model, playbackModel: playbackModel, highlightsOnly: model.showOnlyHighlights,
                                            highlightedIDs: Set(model.annotations.filter { $0.kind == .highlight }.compactMap(\.segmentID)),
                                            activePassageID: activePassageID)
                            .frame(minHeight: 0, maxHeight: .infinity)
                        if !model.gaps.isEmpty {
                            ScrollView(.horizontal) {
                                HStack { ForEach(model.gaps) { gap in Label("\(AppModel.timestamp(gap.startTime)) · \(gap.reason)", systemImage: "waveform.slash").font(.caption).foregroundStyle(.orange) } }
                            }.frame(height: 28).padding(.horizontal, 16)
                        }
                    }.padding(.vertical, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                .frame(minHeight: 0, maxHeight: .infinity)
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
    @State private var editingVersionID = ""
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
            .onChange(of: editing) { _, visible in if visible { editingVersionID = model.activeTranscriptID } }
            .sheet(isPresented: $editing) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Correct transcript").font(.headline)
                    TextEditor(text: $text).frame(width: 480, height: 160)
                    HStack { Button("Cancel") { editing = false }; Spacer(); Button("Save") { model.editSegment(segment, text: text, versionID: editingVersionID); editing = false }.buttonStyle(.borderedProminent) }
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
        }.frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
        .alert("Saved moment label", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("Label", text: $label)
            Button("Cancel", role: .cancel) { editing = nil }
            Button("Save") { if var item = editing { item.label = label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : String(label.prefix(120)); model.saveAnnotation(item) }; editing = nil }
        }
    }
}
