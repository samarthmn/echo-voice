import SwiftUI
import Combine
import EchoCore

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmDelete = false
    @State private var columns = NavigationSplitViewVisibility.all
    private var meetingDays: [Date] { Array(Set(model.meetings.map { Calendar.current.startOfDay(for: $0.startedAt) })).sorted(by: >) }
    private func dayLabel(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(date: .abbreviated, time: .omitted)
    }
    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            VStack(spacing: 0) {
                HStack(spacing: Theme.Space.m) {
                    BrandMark(size: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Echo Voice").font(.headline.weight(.semibold))
                        Text("Private · On this Mac").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                }.padding(Theme.Space.l)
                Divider()
                if !model.searchQuery.isEmpty { searchResults }
                else if model.meetings.isEmpty && model.store != nil {
                    EmptyStateView(title: "No meetings yet", systemImage: "tray", message: "Recorded meetings appear here, grouped by day.") {
                        Button("New Meeting") { model.showNewMeeting = true }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(model.newMeetingBlockedReason != nil)
                    }
                    .frame(maxHeight: .infinity)
                } else { meetingList }
                Divider()
                HStack(spacing: Theme.Space.s) {
                    SetupStatusPill()
                    SettingsLink { Image(systemName: "gearshape").font(.body) }.buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("Settings and local models").accessibilityLabel("Settings")
                }.padding(Theme.Space.m)
            }.navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 380)
        } detail: {
            if let meeting = model.selectedMeeting {
                MeetingDetailView(meeting: meeting, recordingSession: model.recordingSession,
                                  playbackModel: model.playbackModel)
            }
            else { WelcomeView() }
        }
        .searchable(text: $model.searchQuery, placement: .sidebar, prompt: "Search transcripts")
        .tint(Theme.accent)
        .toolbar {
            ToolbarItemGroup {
                Button { model.showNewMeeting = true } label: { Label("New Meeting", systemImage: "plus") }
                    .disabled(model.newMeetingBlockedReason != nil)
                    .help(model.newMeetingBlockedReason ?? "Start a new meeting (⌘N)")
                if model.selectedID != nil {
                    Button { model.exportSelected() } label: { Label("Export", systemImage: "square.and.arrow.up") }
                        .disabled(model.redactionBusy || model.pendingRedactionMeetings.contains(model.selectedID ?? ""))
                        .help("Export notes, transcript and audio")
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
                        .disabled(model.selectedID == model.recordingID || model.redactionBusy
                                  || model.pendingRedactionMeetings.contains(model.selectedID ?? ""))
                        .help(model.selectedID == model.recordingID ? "Stop recording before deleting this meeting" : "Delete this meeting")
                }
            }
        }
        .sheet(isPresented: $model.showNewMeeting) { StartMeetingView().environmentObject(model) }
        .sheet(isPresented: $model.showOnboarding) { OnboardingView().environmentObject(model) }
        // Sheets present their own alerts; a window alert cannot appear above a sheet.
        .alert("Echo Voice", isPresented: Binding(get: { model.error != nil && !model.showNewMeeting && !model.showOnboarding }, set: { if !$0 { model.error = nil } })) {
            if !model.pendingMeetingDeletions.isEmpty { Button("Retry deletion recovery") { model.retryMeetingDeletions() } }
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .confirmationDialog("Delete this meeting and its managed recordings, transcripts, and notes?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Meeting", role: .destructive) { Task { await model.deleteSelected() } }
        } message: { Text("Files you exported separately will remain untouched.") }
    }

    private var searchResults: some View {
        List(Array(model.searchResults.enumerated()), id: \.offset) { _, hit in
            Button {
                model.selectedID = hit.segment.meetingID; model.selectedTab = "Transcript"; model.play(at: hit.segment.startTime, track: hit.segment.track)
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(hit.meetingTitle).font(.caption).foregroundStyle(.secondary)
                    Text(hit.segment.text).lineLimit(3)
                    Text(AppModel.timestamp(hit.segment.startTime)).font(.caption.monospacedDigit()).foregroundStyle(Theme.accent)
                }
            }.buttonStyle(.plain)
        }
        .overlay { if model.searchResults.isEmpty { EmptyStateView(title: "No matches", systemImage: "magnifyingglass", message: "Try a different word from the transcript.") } }
    }

    private var meetingList: some View {
        List(selection: $model.selectedID) {
            ForEach(meetingDays, id: \.self) { day in
                Section(dayLabel(day)) {
                    ForEach(model.meetings.filter { Calendar.current.isDate($0.startedAt, inSameDayAs: day) }) { meeting in
                        MeetingRow(meeting: meeting, recording: meeting.id == model.recordingID, processing: meeting.id == model.processingID).tag(meeting.id)
                    }
                }
            }
        }.listStyle(.sidebar)
    }
}

private struct MeetingRow: View {
    let meeting: Meeting
    let recording: Bool
    let processing: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: meeting.recordingMode == .inPerson ? "person.2" : "video")
                    .font(.caption)
                    .foregroundStyle(recording ? Color.red : Color.secondary)
                Text(meeting.title).font(.callout.weight(.medium)).lineLimit(1)
                Spacer()
                if recording {
                    HStack(spacing: 4) {
                        Circle().fill(.red).frame(width: 7, height: 7)
                        Text("REC").font(.system(size: 9, weight: .bold)).foregroundStyle(.red)
                    }
                    .accessibilityLabel("Recording")
                } else if processing {
                    ProgressView().controlSize(.mini).accessibilityLabel("Processing")
                }
            }
            HStack {
                Text(meeting.startedAt, format: .dateTime.hour().minute())
                if let ended = meeting.endedAt { Text("· " + AppModel.duration(ended.timeIntervalSince(meeting.startedAt))) }
                Spacer()
                if !recording {
                    Text(meeting.state.displayLabel).foregroundStyle(meeting.state.tone == .neutral ? Color.secondary : meeting.state.tone.color)
                }
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 4)
    }
}

extension MeetingState {
    var displayLabel: String {
        switch self {
        case .failed: "Needs attention"
        case .finalizing: "Processing"
        default: rawValue.capitalized
        }
    }
    var tone: StatusTone {
        switch self {
        case .recording: .problem
        case .paused, .interrupted, .failed: .attention
        case .finalizing: .progress
        case .ready: .neutral
        }
    }
}

private struct WelcomeView: View {
    @EnvironmentObject var model: AppModel
    @State private var configuration: ProcessingConfiguration?
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
                    Text("Be in the conversation.").font(Theme.Font.hero)
                    Text("Keep the details here.").font(Theme.Font.hero).foregroundStyle(.secondary)
                }
                Text("Record meeting audio and your microphone, follow the transcript, then review notes linked to what was said. Everything is processed locally.")
                    .foregroundStyle(.secondary).frame(maxWidth: 520, alignment: .leading).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                if readiness.requiredComplete || model.libraryRecovery != nil || !model.runtimeChecked {
                    HStack(spacing: Theme.Space.m) {
                        Button("New Meeting") { model.showNewMeeting = true }.buttonStyle(.borderedProminent).controlSize(.large)
                            .disabled(model.newMeetingBlockedReason != nil).help(model.newMeetingBlockedReason ?? "Start a new meeting")
                        SettingsLink { Text("Manage Models") }.controlSize(.large)
                    }
                    HStack(spacing: Theme.Space.l) { Label("Online or in person", systemImage: "person.2"); Label("No meeting bot", systemImage: "video.slash"); Label("Local only", systemImage: "lock.shield") }
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    setupCard(readiness)
                }
                ModelSummaryView(title: "Models for new meetings", configuration: configuration).frame(maxWidth: 640)
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(Theme.Space.xxl + 8)
            .frame(maxWidth: .infinity)
        }
        // objectWillChange fires before the new value is stored, and download progress publishes often.
        .onReceive(model.objectWillChange.debounce(for: .milliseconds(150), scheduler: RunLoop.main)) { _ in refreshModels() }
        .onAppear { refreshModels() }
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

    private func refreshModels() { configuration = try? model.processingConfiguration(speech: model.defaultModel(.speech) == "parakeet" ? .parakeet : .whisper) }
}
