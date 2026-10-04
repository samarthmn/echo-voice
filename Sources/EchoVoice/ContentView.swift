import SwiftUI
import EchoCore

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var deletionTarget: Meeting?
    @State private var columns = NavigationSplitViewVisibility.all
    private var days: [Date] {
        Array(Set(model.meetings.map { Calendar.current.startOfDay(for: $0.startedAt) })).sorted(by: >)
    }
    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            VStack(spacing: 0) {
                List(selection: $model.selectedID) {
                    if model.searchQuery.isEmpty {
                        ForEach(days, id: \.self) { day in
                            Section(dayLabel(day)) {
                                ForEach(model.meetings.filter { Calendar.current.isDate($0.startedAt, inSameDayAs: day) }) { meeting in
                                    MeetingRow(meeting: meeting, recording: meeting.id == model.recordingID,
                                               processing: meeting.id == model.processingID).tag(meeting.id)
                                }
                            }
                        }
                    } else {
                        ForEach(model.searchResults, id: \.segment.id) { hit in
                            Button {
                                model.selectedID = hit.segment.meetingID
                                model.selectedTab = .transcript
                                model.play(at: hit.segment.startTime, track: hit.segment.track, meetingID: hit.segment.meetingID)
                                Task { await model.transcriptList?.reveal(segmentID: hit.segment.id) }
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(hit.meetingTitle).font(.callout.weight(.medium)).lineLimit(1)
                                    Text(hit.segment.text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                }
                .listStyle(.sidebar)
                .overlay {
                    if model.store != nil && (model.searchQuery.isEmpty ? model.meetings.isEmpty : model.searchResults.isEmpty) {
                        Text(model.searchQuery.isEmpty ? "Your meetings appear here" : "No matching passages")
                            .font(.callout).foregroundStyle(.secondary).padding()
                    }
                }
                Divider()
                HStack {
                    SetupStatusPill()
                    SettingsLink { Image(systemName: "gearshape") }.buttonStyle(.plain)
                        .help("Settings").accessibilityLabel("Settings")
                }.padding(12)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            // The split column owns its size. Do not feed changing content's
            // ideal size (empty transcript, inspector, recording controls) back
            // into AppKit's split-view minimum-size constraint negotiation.
            GeometryReader { available in
                VStack(spacing: 0) {
                    if let meeting = model.selectedMeeting {
                        MeetingDetailView(meeting: meeting, playbackModel: model.playbackModel)
                            .id(meeting.id)
                    } else { WelcomeView() }
                    if model.isRecording {
                        Divider()
                        RecordingBar(session: model.recordingSession)
                    }
                }
                .frame(width: available.size.width, height: available.size.height)
            }
        }
        .searchable(text: $model.searchQuery, placement: .sidebar, prompt: "Search transcripts")
        .navigationTitle(model.selectedMeeting?.title ?? "Echo Voice")
        .tint(Theme.accent)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if model.isRecording {
                    Button("Stop Recording", systemImage: "stop.fill") { Task { await model.stopRecording() } }
                        .labelStyle(.titleAndIcon)
                        .help("Stop and save the active recording (⌘.)")
                        .accessibilityIdentifier("toolbar-stop-recording")
                } else {
                    Button { model.showNewMeeting = true } label: { Label("New Meeting", systemImage: "plus") }
                        .disabled(!model.recordingAvailability.isEnabled || model.showOnboarding)
                        .help(model.newMeetingBlockedReason ?? "New meeting (⌘N)")
                        .accessibilityIdentifier("new-meeting")
                }
            }
            ToolbarItemGroup {
                if let meeting = model.selectedMeeting {
                    Button { model.exportSelected(meetingID: meeting.id) } label: { Label("Export", systemImage: "square.and.arrow.up") }
                        .disabled(model.isRecording || model.redactionBusy || model.pendingRedactionMeetings.contains(meeting.id))
                    Menu {
                        if meeting.state == .interrupted {
                            Button("Resume Recording…") { model.resumeMeeting(meeting.id) }
                                .disabled(model.newMeetingBlockedReason != nil)
                        }
                        Button("Delete Meeting…", role: .destructive) { deletionTarget = meeting }
                            .disabled(meeting.id == model.recordingID || model.redactionBusy || model.pendingRedactionMeetings.contains(meeting.id))
                    } label: { Label("Meeting Actions", systemImage: "ellipsis.circle") }
                    Button { model.workspace.inspectorVisible.toggle() } label: { Label("Meeting Details", systemImage: "sidebar.right") }
                        .help("Models, history, saved moments, and processing")
                }
            }
        }
        .sheet(item: Binding(get: { model.workspace.presentation }, set: { model.workspace.presentation = $0 })) { route in
            switch route {
            case .newMeeting(let resumeID): StartMeetingView(resumeID: resumeID).environmentObject(model)
            case .setup: OnboardingView().environmentObject(model)
            case .inputs(let id): RecordingInputsView(meetingID: id).environmentObject(model)
            }
        }
        .alert("Unable to complete the action", isPresented: Binding(get: { model.error != nil && model.workspace.presentation == nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .confirmationDialog("Delete this meeting?", isPresented: Binding(get: { deletionTarget != nil }, set: { if !$0 { deletionTarget = nil } }), titleVisibility: .visible) {
            if let target = deletionTarget {
                Button("Delete Meeting", role: .destructive) { deletionTarget = nil; Task { await model.deleteSelected(meetingID: target.id) } }
            }
            Button("Cancel", role: .cancel) { deletionTarget = nil }
        } message: { Text("Permanently deletes this meeting’s managed audio, transcripts, and notes. Independent exports remain. This cannot be undone.") }
    }
    private func dayLabel(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(date: .abbreviated, time: .omitted)
    }
}

private struct MeetingRow: View {
    let meeting: Meeting
    let recording: Bool
    let processing: Bool
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: recording ? "record.circle" : meeting.recordingMode == .inPerson ? "person.2" : "video")
                .foregroundStyle(recording ? Color.red : Color.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(meeting.title).font(.callout.weight(.medium)).lineLimit(1)
                Text(meeting.startedAt.formatted(date: .omitted, time: .shortened) + " · " + (recording ? "Recording" : processing ? "Processing" : meeting.state.displayLabel))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }.padding(.vertical, 3)
    }
}
