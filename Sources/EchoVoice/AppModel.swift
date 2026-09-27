import Foundation
import SwiftUI
import AppKit
import AVFoundation
import EchoCore
import EchoCapture
import EchoRuntime
import EchoIntelligence

private struct MeetingDetailSnapshot: Sendable {
    let notes: [MeetingNotes]
    let activeTranscriptID: String
    let annotations: [TranscriptAnnotation]
    let transcriptVersions: [TranscriptVersion]
    let configuration: ProcessingConfiguration?
    let groupingRuns: [SpeakerGroupingRun]
    let availableTracks: Set<AudioTrack>
    let speakers: [Speaker]
    let jobStatus: MeetingStore.JobStatusSummary
    let gaps: [CaptureGap]

    init(store: MeetingStore, meetingID: String) throws {
        notes = try store.notes(meetingID: meetingID)
        activeTranscriptID = try store.activeTranscriptVersion(meetingID: meetingID)
        annotations = try store.annotations(meetingID: meetingID)
        transcriptVersions = try store.transcriptVersions(meetingID: meetingID)
        configuration = try store.configuration(meetingID: meetingID)
        groupingRuns = try store.speakerGroupingRuns(meetingID: meetingID)
        availableTracks = try store.availableTracks(meetingID: meetingID)
        speakers = try store.speakers(meetingID: meetingID)
        jobStatus = try store.jobStatusSummary(meetingID: meetingID)
        gaps = try store.gaps(meetingID: meetingID)
    }
}

@MainActor
final class AppModel: ObservableObject {
    let paths: AppPaths
    private(set) var store: MeetingStore?
    let service: LocalService
    let installer: RuntimeInstaller
    let intelligence: LocalIntelligence
    let ollamaNotes: OllamaNotesClient
    private(set) var processor: MeetingProcessor?
    private var redactor: RedactionCoordinator?
    private let mutationCoordinator = MeetingMutationCoordinator()
    let capture: AudioCaptureController
    let recordingSession = RecordingSessionModel()
    let playbackModel = PlaybackModel()
    @Published var meetings: [Meeting] = []
    @Published var selectedID: String? {
        didSet {
            if oldValue != selectedID {
                stopPlayback(); player = nil; playbackTime = 0
                transcriptList?.reset()
                displayedTranscriptKey = nil
                notes = []; speakers = []; jobStatus = nil; gaps = []; annotations = []
                groupingRuns = []; transcriptVersions = []; availableTracks = []
                speakerTurnIndices = [:]
                selectedConfiguration = nil; activeTranscriptID = ""
            }
            reloadDetail()
        }
    }
    @Published private(set) var transcriptList: TranscriptListModel?
    private var displayedTranscriptKey: String?
    var activePassageID: String? {
        guard playing else { return nil }
        if let playbackTrack { return transcriptList?.activeSegmentID(at: playbackTime, track: playbackTrack) }
        return transcriptList?.activeSegmentID(at: playbackTime, track: .remote)
            ?? transcriptList?.activeSegmentID(at: playbackTime, track: .cleanMicrophone)
            ?? transcriptList?.activeSegmentID(at: playbackTime, track: .microphone)
    }
    @Published var notes: [MeetingNotes] = []
    @Published var speakers: [Speaker] = []
    @Published var jobStatus: MeetingStore.JobStatusSummary?
    @Published var gaps: [CaptureGap] = []
    @Published var sources: [AudioSource] = []
    @Published var microphones: [MicrophoneDevice] = []
    @Published var recordingID: String?
    @Published var microphoneMuted = false
    @Published private(set) var liveTranscriptionPolicy: LiveTranscriptionPolicy?
    @Published var acousticMode: CaptureAcousticMode = .headphones
    @Published var recordingMicrophoneUID: String?
    @Published var recordingApplicationID: String?
    @Published var showInputsPanel = false
    @Published var redactionBusy = false
    @Published private(set) var pendingRedactionMeetings: Set<String> = []
    @Published private(set) var recoveringAssetMeetings: Set<String> = []
    @Published private(set) var damagedAssetMeetings: Set<String> = []
    @Published private(set) var deletingMeetings: Set<String> = []
    @Published private(set) var pendingMeetingDeletions: Set<String> = []
    @Published var changingRecording = false
    @Published var processingID: String?
    @Published var isPaused = false
    var elapsed: Double { get { recordingSession.elapsed } set { recordingSession.elapsed = newValue } }
    var microphoneLevel: Float { get { recordingSession.microphoneLevel } set { recordingSession.microphoneLevel = newValue } }
    var remoteLevel: Float { get { recordingSession.remoteLevel } set { recordingSession.remoteLevel = newValue } }
    @Published var waitingForRemoteAudio = false
    @Published var status = "Ready when you are"
    @Published var error: String?
    @Published var libraryRecovery: String?
    @Published private(set) var libraryPhase: LibraryOpenPhase = .opening
    private var isShuttingDown = false
    private var libraryOpenTask: Task<Void, Never>?
    @Published var showNewMeeting = false
    @Published var health: ServiceHealth?
    @Published var setupBusy = false
    @Published var setupProgress = "Install local models to get started."
    @Published var runtimeChecked = false
    @Published var activeDownload: ModelDownload?
    @Published var queuedDownloads: [ModelDownload] = []
    @Published var microphonePermission = CapturePermissions.microphoneState
    @Published var meetingAudioPermission = PermissionState(rawValue: UserDefaults.standard.string(forKey: AppModel.meetingAudioPermissionKey) ?? "") ?? .notDetermined
    @Published var showOnboarding = false
    @Published var ollamaModels: [OllamaModel] = []
    @Published var ollamaStatus = "Ollama has not been checked."
    @Published var ollamaChecked = false
    @Published var refreshingOllama = false
    @Published var testingInputs = false
    @Published var cancellingPreparation = false
    @Published var inputTestPassed = false
    @Published var searchQuery = "" { didSet { search() } }
    @Published var searchResults: [SearchHit] = []
    @Published var selectedTab = "Transcript"
    @Published var activeTranscriptID = ""
    @Published var annotations: [TranscriptAnnotation] = []
    @Published var followPlayback = true
    @Published var playbackTrack: AudioTrack?
    @Published var showOnlyHighlights = false
    @Published var transcriptVersions: [TranscriptVersion] = []
    @Published var readyTranscriptID: String?
    @Published var selectedConfiguration: ProcessingConfiguration?
    @Published var groupingRuns: [SpeakerGroupingRun] = []
    private var speakerTurnIndices: [String: SpeakerTurnIndex] = [:]
    @Published var availableTracks: Set<AudioTrack> = []
    @Published var settingsPage = SettingsPage.models
    @Published var settingsModelRole: ModelRole = .speech
    @Published var importingLibrary = false
    @Published var libraryImportPending = false
    var playing: Bool { get { playbackModel.playing } set { playbackModel.playing = newValue } }
    @Published var playbackRate: Float = 1 { didSet { player?.rate = playbackRate } }
    var playbackTime: Double { get { playbackModel.time } set { playbackModel.time = newValue } }
    private var searchTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var detailGeneration = 0
    private var pendingDetailRefresh = false
    private var clock: Timer?
    private var lastElapsedSecond = -1
    private var lastMicrophoneMeterAt = -Double.infinity
    private var lastRemoteMeterAt = -Double.infinity
    private var refreshTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private var compactionTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    var setupTask: Task<Void, Never>?
    private var player: MeetingPlayer?
    private var activationObserver: NSObjectProtocol?
    private var preparationTask: Task<Void, Never>?
    private var inputTestCapture: AudioCaptureController?
    private var stoppingRecording = false

    var isRecording: Bool { recordingID != nil }
    var selectedMeeting: Meeting? { meetings.first { $0.id == selectedID } }
    var latestNotes: MeetingNotes? { notes.first }

    init(capture: AudioCaptureController? = nil) {
        self.capture = capture ?? AudioCaptureController()
        let localPaths: AppPaths
        if let override = ProcessInfo.processInfo.environment["ECHO_DATA_ROOT"], !override.isEmpty { localPaths = AppPaths(root: URL(fileURLWithPath: override)) }
        else { localPaths = .default }
        paths = localPaths
        store = nil
        let localService = LocalService(paths: localPaths)
        let ollamaClient = OllamaNotesClient()
        let localIntelligence = LocalIntelligence(modelsURL: localPaths.modelsURL, ollama: ollamaClient)
        service = localService; installer = RuntimeInstaller(paths: localPaths); intelligence = localIntelligence; ollamaNotes = ollamaClient
        processor = nil
        status = "Opening your library"
        libraryOpenTask = Task.detached(priority: .userInitiated) { [localPaths] in
            let opened = Result { try Self.openLibrary(localPaths) }
            await MainActor.run { [weak self] in self?.finishOpeningLibrary(opened) }
        }
        clock = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.isRecording {
                    let current = self.capture.currentTime
                    let second = Int(current)
                    if second != self.lastElapsedSecond {
                        self.lastElapsedSecond = second
                        self.elapsed = current
                    }
                }
                if let player = self.player {
                    let position = player.currentTime
                    if abs(self.playbackTime - position) >= 0.025 { self.playbackTime = position }
                    if self.playing != player.isPlaying { self.playing = player.isPlaying }
                }
            }
        }
        // Returning from System Settings is the usual way permissions change.
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }
    }

    nonisolated private static func openLibrary(_ paths: AppPaths) throws -> MeetingStore {
        try LibraryImport.activatePending(destination: paths)
        let store = try MeetingStore(paths: paths, deferAssetRecovery: true)
        _ = try store.recoverInterruptedMeetings()
        try store.recoverRunningJobs()
        return store
    }

    private func finishOpeningLibrary(_ result: Result<MeetingStore, Error>) {
        if isShuttingDown { return }
        switch result {
        case .success(let opened):
            store = opened
            transcriptList = TranscriptListModel(store: opened)
            processor = MeetingProcessor(store: opened, paths: paths, service: service, intelligence: intelligence)
            redactor = RedactionCoordinator(store: opened, paths: paths)
            pendingRedactionMeetings = Set((try? opened.pendingRedactions().map(\.meetingID)) ?? [])
            pendingMeetingDeletions = Set(opened.deletionRecoveryIssues.map(\.meetingID))
            recoveringAssetMeetings = Set((try? opened.meetings().map(\.id)) ?? [])
            damagedAssetMeetings = []
            libraryRecovery = nil
            libraryPhase = .ready
            status = "Ready when you are"
            reload()
            selectedID = meetings.first?.id
            reloadDetail()
            Task.detached(priority: .utility) { [weak self, opened] in
                do { try opened.retireVisualContext() }
                catch { await MainActor.run { [weak self] in self?.error = "Some retired visual files still need cleanup: " + error.localizedDescription } }
            }
            Task { [weak self, opened] in
                guard let self else { return }
                do {
                    try await self.recoverMeetingDeletionIntents(store: opened)
                    let issues = opened.deletionRecoveryIssues
                    if let issue = issues.first {
                        self.error = "A meeting deletion needs recovery: " + issue.message + ". Other meetings are available."
                    }
                } catch { self.error = "Could not recover meeting deletions: " + error.localizedDescription }
                for id in self.pendingRedactionMeetings.sorted() {
                    do {
                        try await self.mutationCoordinator.withLease(meetingID: id, access: .exclusive) {
                            try await self.redactor?.recoverPending(meetingID: id)
                        }
                        self.pendingRedactionMeetings.remove(id)
                    } catch {
                        self.error = "A passage deletion needs recovery for \(id): " + error.localizedDescription
                    }
                }
                self.reload(); self.reloadDetail()
                for id in self.recoveringAssetMeetings.sorted() {
                    guard !self.pendingMeetingDeletions.contains(id), (try? opened.meeting(id: id)) != nil else {
                        self.recoveringAssetMeetings.remove(id)
                        continue
                    }
                    do {
                        try await self.mutationCoordinator.withLease(meetingID: id, access: .exclusive) {
                            try await Task.detached(priority: .utility) { try opened.recoverMeetingAsset(meetingID: id) }.value
                        }
                    } catch {
                        self.damagedAssetMeetings.insert(id)
                        self.error = "Audio repair needed for \(id): \(error.localizedDescription). Other meetings are available."
                        self.status = "Some meetings need audio repair"
                    }
                    self.recoveringAssetMeetings.remove(id)
                    self.reload(); self.reloadDetail()
                }
                self.scheduleCompaction(for: self.meetings.filter {
                    $0.state == .ready && !self.damagedAssetMeetings.contains($0.id)
                        && !self.pendingMeetingDeletions.contains($0.id)
                }.map(\.id))
            }
        case .failure(let error):
            store = nil
            processor = nil
            libraryRecovery = LibraryRecovery.message(root: paths.root, reason: error.localizedDescription)
            libraryPhase = .unavailable
            status = "Library needs attention"
        }
        refreshSources()
        Task {
            await refreshHealth()
            if defaultNotesSelection()?.provider == .ollama { await refreshOllamaModels() }
            if libraryPhase == .ready && !readiness.requiredComplete && !UserDefaults.standard.bool(forKey: Self.onboardingDismissedKey) { presentSetupGuide() }
        }
    }

    func reload() { do { meetings = try store?.meetings() ?? [] } catch { self.error = error.localizedDescription } }

    private func assetWorkBlocked(_ meetingID: String) -> Bool {
        if deletingMeetings.contains(meetingID) {
            error = "This meeting is being deleted."
            return true
        }
        if pendingMeetingDeletions.contains(meetingID) {
            error = "A deletion needs recovery for this meeting. Use Retry deletion recovery to continue."
            return true
        }
        if recoveringAssetMeetings.contains(meetingID) {
            error = "Audio recovery is still checking this meeting. Try again shortly."
            return true
        }
        if damagedAssetMeetings.contains(meetingID) {
            error = "This meeting has an audio asset that needs repair before recording, processing, playback, export, or deletion."
            return true
        }
        return false
    }

    func retryAssetRecovery(meetingID: String) {
        guard let store, damagedAssetMeetings.contains(meetingID),
              !recoveringAssetMeetings.contains(meetingID) else { return }
        damagedAssetMeetings.remove(meetingID)
        recoveringAssetMeetings.insert(meetingID)
        Task {
            do {
                try await mutationCoordinator.withLease(meetingID: meetingID, access: .exclusive) {
                    try await Task.detached(priority: .utility) { try store.recoverMeetingAsset(meetingID: meetingID) }.value
                }
                status = "Audio recovery completed for this meeting"
            } catch {
                damagedAssetMeetings.insert(meetingID)
                self.error = "Audio repair still needed for \(meetingID): \(error.localizedDescription)"
            }
            recoveringAssetMeetings.remove(meetingID)
            reload(); reloadDetail()
        }
    }
    func retryMeetingDeletions() {
        guard let store, deletingMeetings.isEmpty else { return }
        Task {
            do {
                try await recoverMeetingDeletionIntents(store: store)
                let issues = store.deletionRecoveryIssues
                if let issue = issues.first { error = "Deletion recovery still needs attention: " + issue.message }
                else { status = "Meeting deletions recovered" }
            } catch { self.error = error.localizedDescription }
            reload(); reloadDetail()
        }
    }

    private func recoverMeetingDeletionIntents(store: MeetingStore) async throws {
        for id in pendingMeetingDeletions.sorted() {
            try await mutationCoordinator.withLease(meetingID: id, access: .exclusive) {
                _ = try await Task.detached(priority: .utility) { try store.recoverDeletionTransactions(meetingID: id) }.value
            }
        }
        pendingMeetingDeletions = Set(store.deletionRecoveryIssues.map(\.meetingID))
    }

    func reloadDetail() {
        detailGeneration += 1
        guard let id = selectedID, let store else {
            notes = []; jobStatus = nil; gaps = []; speakers = []; selectedConfiguration = nil
            groupingRuns = []; availableTracks = []; displayedTranscriptKey = nil
            return
        }
        guard detailTask == nil else { pendingDetailRefresh = true; return }
        let request = detailGeneration
        detailTask = Task { [weak self, store] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try MeetingDetailSnapshot(store: store, meetingID: id) }
            }.value
            guard let self else { return }
            self.detailTask = nil
            if self.detailGeneration == request && self.selectedID == id {
                switch result {
                case .success(let snapshot): self.applyDetail(snapshot, meetingID: id)
                case .failure(let error): self.error = error.localizedDescription
                }
            }
            if self.pendingDetailRefresh {
                self.pendingDetailRefresh = false
                self.reloadDetail()
            }
        }
    }

    private func applyDetail(_ snapshot: MeetingDetailSnapshot, meetingID: String) {
        if notes != snapshot.notes { notes = snapshot.notes }
        if activeTranscriptID != snapshot.activeTranscriptID { activeTranscriptID = snapshot.activeTranscriptID }
        let key = meetingID + "/" + snapshot.activeTranscriptID + "/" + String(selectedMeeting?.transcriptRevision ?? 0)
        if displayedTranscriptKey != key, let transcriptList {
            displayedTranscriptKey = key
            Task { await transcriptList.load(meetingID: meetingID, versionID: snapshot.activeTranscriptID) }
        }
        if annotations != snapshot.annotations { annotations = snapshot.annotations }
        if transcriptVersions != snapshot.transcriptVersions { transcriptVersions = snapshot.transcriptVersions }
        if selectedConfiguration != snapshot.configuration { selectedConfiguration = snapshot.configuration }
        if groupingRuns != snapshot.groupingRuns {
            groupingRuns = snapshot.groupingRuns
            speakerTurnIndices = Dictionary(uniqueKeysWithValues: snapshot.groupingRuns.map { ($0.id, SpeakerTurnIndex(run: $0)) })
        }
        if availableTracks != snapshot.availableTracks { availableTracks = snapshot.availableTracks }
        if speakers != snapshot.speakers { speakers = snapshot.speakers }
        if jobStatus != snapshot.jobStatus { jobStatus = snapshot.jobStatus }
        if gaps != snapshot.gaps { gaps = snapshot.gaps }
    }

    func refreshSources() {
        do { sources = try AudioCaptureController.applications(); microphones = try AudioCaptureController.microphones() }
        catch { self.error = error.localizedDescription }
    }

    func speakerSpans(for segment: TranscriptSegment, run: SpeakerGroupingRun) -> [SpeakerAttributionSpan] {
        (speakerTurnIndices[run.id] ?? SpeakerTurnIndex(run: run)).spans(segment: segment)
    }

    func refreshHealth() async {
        defer { runtimeChecked = true }
        guard await service.installed else { health = nil; return }
        do { health = try await service.health() }
        catch { health = nil; setupProgress = error.localizedDescription }
    }

    func refreshPermissions() {
        let current = CapturePermissions.microphoneState
        if microphonePermission != current { microphonePermission = current }
    }

    func requestMicrophoneAccess() async {
        _ = await CapturePermissions.requestMicrophone()
        refreshPermissions()
    }

    /// There is no public preflight for selected-app audio, so record what capture actually observed.
    func recordMeetingAudio(_ state: PermissionState) {
        guard meetingAudioPermission != state else { return }
        meetingAudioPermission = state
        UserDefaults.standard.set(state.rawValue, forKey: Self.meetingAudioPermissionKey)
    }
    private func observeMeetingAudioFailure(_ error: Error, application: AudioSource?) {
        guard application != nil, case CaptureError.audio(let operation, _) = error, operation.contains("selected-app audio tap") else { return }
        recordMeetingAudio(.denied)
    }

    func testInputs(application: AudioSource?, microphone: MicrophoneDevice?, singleSource: Bool, mode: RecordingMode = .online) async {
        guard !isRecording, !testingInputs, preparationTask == nil else { return }
        cancellingPreparation = false
        let task = Task { await performInputTest(application: mode == .inPerson ? nil : application, microphone: microphone, singleSource: mode == .inPerson || singleSource, mode: mode) }
        preparationTask = task
        await task.value
        preparationTask = nil; cancellingPreparation = false
    }

    /// Cancellation is immediate; cleanup stays on the serialized hardware lane.
    /// Keep the sheet open until cleanup completes so another start cannot race it.
    func cancelPreparation() {
        guard preparationTask != nil else { return }
        cancellingPreparation = true
        preparationTask?.cancel()
        if let inputTestCapture { inputTestCapture.requestCancellation() }
        else { capture.requestCancellation() }
    }

    private func performInputTest(application: AudioSource?, microphone: MicrophoneDevice?, singleSource: Bool, mode: RecordingMode) async {
        testingInputs = true; inputTestPassed = false; microphoneLevel = 0; remoteLevel = 0
        let id = UUID().uuidString
        let directory = paths.root.appendingPathComponent("input-tests").appendingPathComponent(id)
        let testCapture = AudioCaptureController()
        inputTestCapture = testCapture
        defer { testingInputs = false; inputTestCapture = nil; try? FileManager.default.removeItem(at: directory) }
        do {
            try Task.checkCancellation()
            try await testCapture.start(.init(meetingID: id, meetingDirectory: directory, application: application, microphone: microphone, allowSingleSource: singleSource, recordingMode: mode)) { [weak self] event in
                if case .level(let track, let value) = event { Task { @MainActor in
                    if track == .remote { self?.remoteLevel = value; if value > Self.audibleLevel { self?.recordMeetingAudio(.granted) } } else { self?.microphoneLevel = value }
                } }
            }
            refreshPermissions()
            try await Task.sleep(nanoseconds: 5_000_000_000)
            let formats = testCapture.recordingFormats
            guard testCapture.isRecording,
                  formats.count == (application == nil ? 0 : 1) + (microphone == nil ? 0 : 1) else {
                throw RuntimeError.service("The input test was interrupted. Test the selected sources again.")
            }
            _ = try CaptureStorageEstimate.calculate(formats: formats, echoCancellation: false)
            await testCapture.stop()
            try Task.checkCancellation()
            inputTestPassed = true
        } catch is CancellationError { await testCapture.stop(); status = "Input test cancelled" }
        catch { await testCapture.stop(); refreshPermissions(); observeMeetingAudioFailure(error, application: application); self.error = error.localizedDescription }
    }

    func startMeeting(title: String, application: AudioSource?, microphone: MicrophoneDevice?, singleSource: Bool, echoCancellation: Bool, consent: Bool, speechModel: SpeechRecognitionModel = .whisper, resumeID: String? = nil, mode: RecordingMode = .online, microphoneMuted: Bool = false, liveTranscription: Bool = true, speakerModelID: String? = nil) async {
        guard preparationTask == nil else { return }
        cancellingPreparation = false
        let task = Task { await performStartMeeting(title: title, application: mode == .inPerson ? nil : application, microphone: microphone, singleSource: mode == .inPerson || singleSource, echoCancellation: mode == .online && echoCancellation, consent: consent, speechModel: speechModel, resumeID: resumeID, mode: mode, microphoneMuted: microphoneMuted, liveTranscription: liveTranscription, speakerModelID: speakerModelID) }
        preparationTask = task
        await task.value
        preparationTask = nil; cancellingPreparation = false
    }

    private func performStartMeeting(title: String, application: AudioSource?, microphone: MicrophoneDevice?, singleSource: Bool, echoCancellation: Bool, consent: Bool, speechModel: SpeechRecognitionModel, resumeID: String?, mode: RecordingMode, microphoneMuted: Bool, liveTranscription: Bool, speakerModelID: String?) async {
        if let reason = startBlockedReason(consent: consent) { self.error = reason; return }
        if let resumeID, assetWorkBlocked(resumeID) { return }
        guard let store, let processor else { return }
        changingRecording = true
        defer { changingRecording = false }
        do {
            try Task.checkCancellation()
            let values = try paths.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
            guard let capacity = values.volumeAvailableCapacityForImportantUsage ?? values.volumeAvailableCapacity.map({ Int64($0) }) else {
                throw RuntimeError.service("Available disk space could not be checked. Check the recording location and try again.")
            }
            compactionTask?.cancel()
            await compactionTask?.value
            compactionTask = nil
            processingTask?.cancel(); await processor.cancel(); await processingTask?.value; processingID = nil
            try Task.checkCancellation()
            stopPlayback()
            let effectiveAcousticMode: CaptureAcousticMode = echoCancellation && application != nil && microphone != nil ? .speakerphone : .headphones
            var meeting: Meeting
            var offset = 0.0
            let effectiveMicrophoneMuted: Bool
            if let resumeID, let recovered = try store.meeting(id: resumeID) {
                let saved = try store.captureSessionSettings(meetingID: resumeID)
                let resumed = try CaptureResumePolicy.validate(meeting: recovered, saved: saved,
                                                               mode: mode, applicationID: application?.id,
                                                               microphoneUID: microphone?.id,
                                                               acousticMode: effectiveAcousticMode)
                meeting = recovered; offset = max(Date().timeIntervalSince(meeting.startedAt), try store.chunks(meetingID: resumeID).map { $0.startTime + $0.duration }.max() ?? 0)
                effectiveMicrophoneMuted = resumed.microphoneMuted
                let previousEnd = try store.chunks(meetingID: resumeID).map { $0.startTime + $0.duration }.max() ?? 0
                try store.addGap(.init(id: UUID().uuidString, meetingID: resumeID, startTime: previousEnd, endTime: offset, reason: "Recording recovered after an interruption"))
                meeting.state = .recording; meeting.endedAt = nil; try store.updateMeeting(meeting)
            } else {
                effectiveMicrophoneMuted = microphoneMuted
                meeting = Meeting(id: UUID().uuidString, title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled meeting" : title, startedAt: Date(), endedAt: nil, state: .recording, language: "en", sourceName: mode == .inPerson ? "Room microphone" : application?.name ?? "Microphone only", usesEchoCancellation: echoCancellation && application != nil && microphone != nil, transcriptRevision: 0, speechModel: speechModel, recordingMode: mode)
                try store.createMeeting(meeting)
                try store.setInitialLiveTranscriptionPolicy(meetingID: meeting.id, enabled: liveTranscription)
                var configuration = try processingConfiguration(speech: speechModel, speakerModelID: speakerModelID)
                configuration.recordingMode = mode
                try store.setConfiguration(meetingID: meeting.id, configuration: configuration)
            }
            let meetingID = meeting.id
            let policy = try store.liveTranscriptionPolicy(meetingID: meetingID)
            let sessionSettings = CaptureSessionSettings(microphoneUID: microphone?.id, applicationID: application?.id,
                                                         microphoneMuted: effectiveMicrophoneMuted,
                                                         acousticMode: effectiveAcousticMode)
            try store.setCaptureSessionSettings(meetingID: meetingID, settings: sessionSettings)
            recordingID = meetingID; selectedID = meetingID; isPaused = false; waitingForRemoteAudio = false
            recordingMicrophoneUID = microphone?.id; recordingApplicationID = application?.id
            do {
                let useAEC = echoCancellation && application != nil && microphone != nil
                try await capture.start(.init(meetingID: meetingID, meetingDirectory: paths.meetingDirectory(meetingID), application: application, microphone: microphone, allowSingleSource: singleSource, initialOffset: offset, recordingMode: mode, initialMicrophoneMuted: effectiveMicrophoneMuted, formatPreflight: { formats in
                    let estimate = try CaptureStorageEstimate.calculate(formats: formats, echoCancellation: useAEC).requiredBytes
                    guard capacity >= estimate else { throw RuntimeError.service("An eight-hour session needs approximately \(ByteCountFormatter.string(fromByteCount: estimate, countStyle: .file)) free. Free space before recording.") }
                })) { [weak self, store] event in
                    // Persist on the recording writer's non-real-time queue before it acknowledges the chunk.
                    do {
                        switch event {
                        case .chunk(let chunk):
                            if chunk.track == .microphone,
                               try store.microphoneProcessingEpoch(meetingID: chunk.meetingID, epochID: chunk.epochID) == nil {
                                let mode = try store.captureSessionSettings(meetingID: chunk.meetingID).acousticMode
                                let asset = try store.paths.resolveMeetingAsset(meetingID: chunk.meetingID, relativePath: chunk.relativePath)
                                let channels = try AVAudioFile(forReading: asset).fileFormat.channelCount
                                try store.saveMicrophoneProcessingEpoch(MicrophoneProcessingEpoch(
                                    meetingID: chunk.meetingID, epochID: chunk.epochID,
                                    startTime: chunk.startTime, sampleRate: chunk.sampleRate,
                                    channels: channels, acousticMode: mode
                                ))
                            }
                            try store.addChunk(chunk)
                        case .gap(let gap): try store.addGap(gap)
                        case .trackEvent(let trackEvent): try store.saveCaptureTrackEvent(trackEvent)
                        default: break
                        }
                        Task { @MainActor in self?.handleCapture(event) }
                    } catch { Task { @MainActor in self?.error = error.localizedDescription; await self?.pauseForStorageFailure() } }
                }
                try Task.checkCancellation()
            } catch { await capture.stop(); refreshPermissions(); observeMeetingAudioFailure(error, application: application); meeting.state = .interrupted; try store.updateMeeting(meeting); recordingID = nil; throw error }
            refreshPermissions()
            self.microphoneMuted = capture.microphoneMuted
            liveTranscriptionPolicy = policy
            self.acousticMode = sessionSettings.acousticMode
            UserDefaults.standard.set(mode.rawValue, forKey: "lastRecordingMode")
            showNewMeeting = false; status = "Recording locally"; reload()
            await processor.startLive(meetingID: meetingID) { [weak self] message in Task { @MainActor in self?.status = message; self?.scheduleRefresh() } }
        } catch is CancellationError { await capture.stop(); status = "Start cancelled. Any saved audio is retained."; reload() }
        catch { self.error = error.localizedDescription; reload() }
    }

    private func handleCapture(_ event: CaptureEvent) {
        switch event {
        case .level(let track, let value):
            let now = ProcessInfo.processInfo.systemUptime
            if track == .remote {
                if value > Self.audibleLevel { recordMeetingAudio(.granted) }
                if now - lastRemoteMeterAt >= 0.1 { remoteLevel = value; lastRemoteMeterAt = now }
            } else if now - lastMicrophoneMeterAt >= 0.1 {
                microphoneLevel = value; lastMicrophoneMeterAt = now
            }
        case .chunk: scheduleRefresh()
        case .gap(let gap):
            if gap.reason.hasPrefix("Waiting for the selected application") { waitingForRemoteAudio = gap.endTime == nil }
            scheduleRefresh()
        case .trackEvent: scheduleRefresh()
        case .interrupted(let reason), .sourceChanged(let reason): isPaused = true; waitingForRemoteAudio = false; status = reason; setRecordingState(.interrupted)
        case .trackChanged(let track, let reason):
            status = reason; refreshSources(); scheduleRefresh()
            if track == .microphone { microphoneMuted = capture.microphoneMuted }
        case .lowDisk(let remaining): status = "Low space: \(ByteCountFormatter.string(fromByteCount: remaining, countStyle: .file)) available"; if remaining < 1_000_000_000 { Task { await stopRecording() } }
        }
    }

    private func pauseForStorageFailure() async {
        do {
            try await capture.pause()
            isPaused = true
            setRecordingState(.interrupted)
        } catch {
            self.error = "Could not pause recording after a storage failure: \(error.localizedDescription)"
        }
    }
    private func setRecordingState(_ state: MeetingState) { guard let id = recordingID, var meeting = try? store?.meeting(id: id) else { return }; meeting.state = state; try? store?.updateMeeting(meeting); reload() }
    private func scheduleRefresh() { guard refreshTask == nil else { return }; refreshTask = Task { try? await Task.sleep(nanoseconds: 300_000_000); reload(); reloadDetail(); refreshTask = nil } }

    func togglePause() async {
        guard let id = recordingID, !changingRecording, !stoppingRecording else { return }
        changingRecording = true
        defer { if recordingID == id, !stoppingRecording { changingRecording = false } }
        do {
            let wasPaused = isPaused
            if wasPaused { try await capture.resume() } else { try await capture.pause() }
            guard recordingID == id, !stoppingRecording else { return }
            isPaused = !wasPaused
            status = wasPaused ? "Recording locally" : "Paused"
            setRecordingState(wasPaused ? .recording : .paused)
        } catch { if recordingID == id, !stoppingRecording { self.error = error.localizedDescription } }
    }

    func stopLiveTranscription() async {
        guard let id = recordingID, liveTranscriptionPolicy?.admitsLiveRecognition == true,
              let processor else { return }
        do {
            try await processor.stopLiveTranscription(meetingID: id, effectiveTime: capture.currentTime)
            liveTranscriptionPolicy = try store?.liveTranscriptionPolicy(meetingID: id)
            status = "Live transcription stopped. Remaining speech will be transcribed after the meeting."
        } catch { self.error = error.localizedDescription }
    }

    func setMicrophoneMuted(_ muted: Bool) async {
        guard let id = recordingID, let store else { return }
        do {
            try await capture.setMicrophoneMuted(muted)
            microphoneMuted = capture.microphoneMuted
            var settings = try store.captureSessionSettings(meetingID: id)
            settings.microphoneMuted = capture.microphoneMuted
            try store.setCaptureSessionSettings(meetingID: id, settings: settings)
            microphoneMuted = capture.microphoneMuted
            microphoneLevel = muted ? 0 : microphoneLevel
            status = muted ? "Microphone muted in Echo Voice. Meeting audio continues." : "Microphone recording resumed."
        } catch {
            microphoneMuted = capture.microphoneMuted
            self.error = error.localizedDescription
        }
    }

    func changeMicrophone(uid: String) async {
        guard let id = recordingID, let store else { return }
        do {
            try await capture.changeMicrophone(uid: uid)
            recordingMicrophoneUID = uid
            microphoneMuted = capture.microphoneMuted
            var settings = try store.captureSessionSettings(meetingID: id)
            settings.microphoneUID = uid
            settings.microphoneMuted = capture.microphoneMuted
            try store.setCaptureSessionSettings(meetingID: id, settings: settings)
            recordingMicrophoneUID = uid
            microphoneMuted = capture.microphoneMuted
            status = "Microphone input changed."
        } catch {
            microphoneMuted = capture.microphoneMuted
            self.error = "Could not switch microphone: " + error.localizedDescription
        }
    }

    func changeApplication(sourceID: String) async {
        guard let id = recordingID, let store else { return }
        do {
            try await capture.changeApplication(sourceID: sourceID)
            recordingApplicationID = sourceID
            var settings = try store.captureSessionSettings(meetingID: id)
            settings.applicationID = sourceID
            try store.setCaptureSessionSettings(meetingID: id, settings: settings)
            recordingApplicationID = sourceID
            status = "Selected meeting application changed."
        } catch { self.error = "Could not switch meeting application: " + error.localizedDescription }
    }

    func setAcousticMode(_ mode: CaptureAcousticMode) async {
        guard let id = recordingID, let store, selectedMeeting?.recordingMode == .online else { return }
        do {
            var settings = try store.captureSessionSettings(meetingID: id)
            guard settings.acousticMode != mode else { return }
            guard mode != .speakerphone || (settings.microphoneUID != nil && settings.applicationID != nil) else {
                throw EchoCoreError.invalidValue("Select a microphone and meeting application before enabling Speakerphone")
            }
            let commitMode = {
                // Source and mute choices may have changed while teardown waited.
                var current = try store.captureSessionSettings(meetingID: id)
                current.acousticMode = mode
                current.microphoneMuted = self.capture.microphoneMuted
                try store.setCaptureSessionSettings(meetingID: id, settings: current)
                self.acousticMode = mode
            }
            if recordingMicrophoneUID != nil {
                try await capture.reconfigureMicrophone(reason: "Acoustic processing mode changed", configuration: commitMode)
            } else { try commitMode() }
            guard recordingID == id, !stoppingRecording else { return }
            microphoneMuted = capture.microphoneMuted
            settings = try store.captureSessionSettings(meetingID: id)
            settings.microphoneMuted = capture.microphoneMuted
            try store.setCaptureSessionSettings(meetingID: id, settings: settings)
            status = mode == .speakerphone ? "Speakerphone processing will apply to new microphone audio." : "Headphones mode will use new raw microphone audio."
        } catch {
            microphoneMuted = capture.microphoneMuted
            self.error = "Could not change acoustic mode: " + error.localizedDescription
        }
    }

    func stopRecording(finalize: Bool = true) async {
        guard let id = recordingID, !stoppingRecording else { return }
        stoppingRecording = true
        defer { stoppingRecording = false }
        capture.requestCancellation()
        changingRecording = true

        await capture.stop()
        // Finalize durable audio before starting post-processing.
        await processor?.stopLive()
        recordingID = nil; isPaused = false; microphoneLevel = 0; remoteLevel = 0; waitingForRemoteAudio = false
        liveTranscriptionPolicy = nil
        microphoneMuted = false; recordingMicrophoneUID = nil; recordingApplicationID = nil; showInputsPanel = false
        acousticMode = .headphones
        do { if var meeting = try store?.meeting(id: id) { meeting.endedAt = Date(); meeting.state = .finalizing; try store?.updateMeeting(meeting) } }
        catch { self.error = error.localizedDescription }
        reload(); reloadDetail()
        changingRecording = false
        if finalize { processMeeting(id) } else { startNextDownload() }
    }

    func processMeeting(_ id: String, windowedSpeakers: Bool = false) {
        guard !assetWorkBlocked(id) else { return }
        guard !isRecording, !changingRecording, !setupBusy, !redactionBusy,
              !pendingRedactionMeetings.contains(id), processingID == nil, let processor else { return }
        processingID = id
        processingTask = Task { [self] in
            defer { processingID = nil; reload(); reloadDetail(); startNextDownload() }
            do {
                try await mutationCoordinator.withLease(meetingID: id, access: .exclusive) {
                    try await processor.finalize(meetingID: id, diarizationWindowSeconds: windowedSpeakers ? 1800 : nil) { [weak self] message in
                        Task { @MainActor in self?.status = message; self?.scheduleRefresh() }
                    }
                }
                status = "Ready to review"
                scheduleCompaction(for: [id])
            }
            catch is CancellationError { status = "Processing paused" }
            catch { self.error = error.localizedDescription; status = "Transcript and saved audio retained. Processing needs attention." }
        }
    }

    private func scheduleCompaction(for meetingIDs: [String]) {
        let eligible = meetingIDs.filter { !pendingMeetingDeletions.contains($0) && !deletingMeetings.contains($0) }
        guard let store, !eligible.isEmpty else { return }
        let coordinator = mutationCoordinator
        compactionTask?.cancel()
        compactionTask = Task.detached(priority: .utility) {
            let compactor = AudioCompactor(store: store)
            for id in eligible {
                guard !Task.isCancelled else { return }
                _ = try? await coordinator.withLease(meetingID: id, access: .exclusive) {
                    try await compactor.compact(meetingID: id)
                }
            }
        }
    }

    func saveAnnotation(_ annotation: TranscriptAnnotation) {
        do { try store?.saveAnnotation(annotation); reloadDetail() } catch { self.error = error.localizedDescription }
    }
    func removeAnnotation(_ annotation: TranscriptAnnotation) {
        do { try store?.removeAnnotation(id: annotation.id, meetingID: annotation.meetingID); reloadDetail() } catch { self.error = error.localizedDescription }
    }
    func bookmark(at time: Double? = nil) {
        guard let id = selectedID, !isRecording else { return }
        do { try store?.saveAnnotation(.init(meetingID: id, kind: .bookmark, track: playbackTrack, startTime: time ?? playbackTime)); reloadDetail() } catch { self.error = error.localizedDescription }
    }
    func highlight(_ segment: TranscriptSegment, range: NSRange) {
        guard !segment.isProvisional, range.length > 0, range.location >= 0, NSMaxRange(range) <= (segment.text as NSString).length, let store else { return }
        do {
            let version = try store.activeTranscriptVersion(meetingID: segment.meetingID)
            if let existing = annotations.first(where: { $0.kind == .highlight && $0.transcriptVersionID == version && $0.segmentID == segment.id && $0.location == range.location && $0.length == range.length }) { try store.removeAnnotation(id: existing.id, meetingID: segment.meetingID) }
            else {
                let words = (segment.words ?? []).filter { NSIntersectionRange($0.range, range).length > 0 }
                try store.saveAnnotation(.init(meetingID: segment.meetingID, kind: .highlight, transcriptVersionID: version, segmentID: segment.id, location: range.location, length: range.length, quote: (segment.text as NSString).substring(with: range), track: segment.track, startTime: words.first?.start ?? segment.startTime, endTime: words.last?.end ?? segment.endTime))
            }
            reloadDetail()
        } catch { self.error = error.localizedDescription }
    }
    func isAudible(_ track: AudioTrack) -> Bool {
        if let playbackTrack { return playbackTrack == track }
        return track == .remote || track == (selectedMeeting?.usesEchoCancellation == true ? .cleanMicrophone : .microphone)
    }

    func regenerateTranscript(speech: SpeechRecognitionModel, useVocabulary: Bool) {
        if let id = selectedID, assetWorkBlocked(id) { return }
        guard let id = selectedID, let processor, modelChangesAllowed,
              !redactionBusy, !pendingRedactionMeetings.contains(id) else { return }
        processingID = id
        processingTask = Task {
            defer { processingID = nil; reloadDetail(); startNextDownload() }
            do {
                let configuration = try processingConfiguration(speech: speech, includeVocabulary: useVocabulary)
                let version = try await mutationCoordinator.withLease(meetingID: id, access: .exclusive) { [weak self] in
                    try await processor.regenerate(meetingID: id, configuration: configuration) { [weak self] message in
                        Task { @MainActor in self?.status = message }
                    }
                }
                // Explicit activation also protects edits in an open transcript editor.
                readyTranscriptID = version; status = "New transcript ready. Switch when you finish reviewing."
            } catch is CancellationError { status = "Regeneration cancelled. Previous transcript retained." }
            catch { self.error = error.localizedDescription }
        }
    }
    func activateTranscript(_ version: String) {
        guard let id = selectedID, !isRecording, !playing, !redactionBusy,
              !pendingRedactionMeetings.contains(id), processingID == nil else { return }
        do { stopPlayback(); try store?.activateTranscriptVersion(version, meetingID: id); readyTranscriptID = nil; reload(); reloadDetail(); search() }
        catch { self.error = error.localizedDescription }
    }

    func editSegment(_ segment: TranscriptSegment, text: String) {
        guard !redactionBusy, !pendingRedactionMeetings.contains(segment.meetingID) else { return }
        do { try store?.editSegment(id: segment.id, text: text); reload(); reloadDetail(); search() }
        catch { self.error = error.localizedDescription }
    }
    func previewPassageDeletion(_ segment: TranscriptSegment) async -> RedactionPreview? {
        guard !assetWorkBlocked(segment.meetingID) else { return nil }
        guard !isRecording, !redactionBusy, !pendingRedactionMeetings.contains(segment.meetingID), let redactor else { return nil }
        do { return try await redactor.preview(meetingID: segment.meetingID, segmentID: segment.id) }
        catch { self.error = error.localizedDescription; return nil }
    }

    func deletePassageAndAudio(_ preview: RedactionPreview) async {
        guard !assetWorkBlocked(preview.meetingID) else { return }
        guard !isRecording, !redactionBusy, let redactor else { return }
        redactionBusy = true
        pendingRedactionMeetings.insert(preview.meetingID)
        defer { redactionBusy = false; reload(); reloadDetail(); search() }
        processingTask?.cancel()
        await processor?.cancel()
        await processingTask?.value
        compactionTask?.cancel()
        await compactionTask?.value
        await exportTask?.value
        stopPlayback(); player = nil
        do {
            try await mutationCoordinator.withLease(meetingID: preview.meetingID, access: .exclusive) {
                try await redactor.commit(preview: preview)
            }
            pendingRedactionMeetings.remove(preview.meetingID)
            status = "Passage and managed audio deleted."
        } catch {
            pendingRedactionMeetings = Set((try? store?.pendingRedactions().map(\.meetingID)) ?? [])
            self.error = pendingRedactionMeetings.contains(preview.meetingID)
                ? "Passage deletion needs recovery: " + error.localizedDescription
                : error.localizedDescription
        }
    }

    func retryPendingRedactions() {
        guard !redactionBusy, let redactor else { return }
        redactionBusy = true
        Task {
            defer { redactionBusy = false; reload(); reloadDetail(); search() }
            for id in pendingRedactionMeetings.sorted() {
                do {
                    try await mutationCoordinator.withLease(meetingID: id, access: .exclusive) {
                        try await redactor.recoverPending(meetingID: id)
                    }
                    pendingRedactionMeetings.remove(id)
                } catch { self.error = "Passage deletion needs recovery for \(id): " + error.localizedDescription }
            }
        }
    }
    func renameSpeaker(_ speaker: Speaker, label: String) { do { try store?.renameSpeaker(id: speaker.id, label: label); reloadDetail() } catch { self.error = error.localizedDescription } }
    var availableSpeakerModels: [ModelDescriptor] { catalog?.models(for: .speakers) ?? [] }

    func groupSpeakersForReview(modelID: String) {
        if let id = selectedID, assetWorkBlocked(id) { return }
        guard let id = selectedID, !isRecording, !redactionBusy,
              !pendingRedactionMeetings.contains(id), processingID == nil,
              let processor, let catalog else {
            error = "Set up the local speaker-grouping model in Settings before reviewing speakers."
            return
        }
        guard let descriptor = catalog.model(modelID), descriptor.role == .speakers,
              health?.models[descriptor.id]?.ready == true else {
            error = "Set up the local speaker-grouping model in Settings before reviewing speakers."
            return
        }
        let version = activeTranscriptID
        processingID = id
        processingTask = Task { [self] in
            defer { processingID = nil; reloadDetail() }
            do {
                try await mutationCoordinator.withLease(meetingID: id, access: .exclusive) {
                    try await processor.groupSpeakers(meetingID: id, versionID: version,
                                                      model: ModelSelection(id: descriptor.id, revision: descriptor.revision))
                }
                status = "Speaker groups are ready to review."
            } catch { self.error = error.localizedDescription }
        }
    }

    func speakerPreviews(for run: SpeakerGroupingRun) async throws -> [String: [SpeakerPreview]] {
        guard let store else { return [:] }
        return try await Task.detached {
            let chunks = try store.chunks(meetingID: run.meetingID, track: run.track)
            let trackEvents = try store.captureTrackEvents(meetingID: run.meetingID)
                .reduce(into: [String: AudioTrack]()) { $0[$1.id] = $1.track }
            let gaps = try store.gaps(meetingID: run.meetingID).compactMap { gap -> Range<Double>? in
                guard trackEvents[gap.id] == nil || trackEvents[gap.id] == run.track,
                      let end = gap.endTime, end > gap.startTime else { return nil }
                return gap.startTime..<end
            }
            return SpeakerPreviewSelector.previews(for: run, coverage: chunks, redactions: gaps)
        }.value
    }

    func playSpeakerPreview(_ preview: SpeakerPreview, meetingID: String) {
        guard !assetWorkBlocked(meetingID) else { return }
        guard !isRecording, !redactionBusy, !pendingRedactionMeetings.contains(meetingID),
              selectedID == meetingID, let store else { return }
        do {
            let chunks = try store.chunks(meetingID: meetingID, track: preview.track)
            let selected = chunks.filter { $0.startTime < preview.end && $0.startTime + $0.duration > preview.start }
            guard !selected.isEmpty else { throw RuntimeError.service("This speaker sample is no longer available.") }
            stopPlayback()
            let player = try MeetingPlayer(directory: paths.meetingDirectory(meetingID), chunks: selected, audioAssets: store.audioAssets)
            player.rate = 1
            player.onError = { [weak self] message in self?.error = message }
            self.player = player
            playbackTrack = preview.track
            try player.play(range: preview.start..<preview.end)
            playing = true
            playbackTime = preview.start
        } catch { self.error = error.localizedDescription }
    }
    func saveNotes(_ draft: MeetingNotes) { do { var draft = draft; draft.id = UUID().uuidString; draft.createdAt = Date(); draft.isEdited = true; try store?.saveNotes(draft); reloadDetail() } catch { self.error = error.localizedDescription } }
    func renameMeeting(_ title: String) { guard var meeting = selectedMeeting else { return }; meeting.title = title; do { try store?.updateMeeting(meeting); reload() } catch { self.error = error.localizedDescription } }
    func search() {
        searchTask?.cancel()
        let query = searchQuery
        guard !query.isEmpty, let store else { searchResults = []; return }
        searchTask = Task {
            do {
                try await Task.sleep(nanoseconds: 200_000_000)
                let results = try await Task.detached { try store.search(query) }.value
                try Task.checkCancellation()
                if searchQuery == query { searchResults = results }
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }

    func exportSelected() {
        if let id = selectedID, assetWorkBlocked(id) { return }
        guard let id = selectedID, let store, !redactionBusy,
              !pendingRedactionMeetings.contains(id) else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true; panel.prompt = "Export Here"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let accessed = destination.startAccessingSecurityScopedResource()
        let coordinator = mutationCoordinator
        exportTask = Task {
            defer { if accessed { destination.stopAccessingSecurityScopedResource() } }
            do {
                let output = try await coordinator.withLease(meetingID: id, access: .read) {
                    try await Task.detached { try MeetingExporter(store: store).export(meetingID: id, to: destination) }.value
                }
                NSWorkspace.shared.activateFileViewerSelecting([output]); status = "Export saved"
            } catch { self.error = error.localizedDescription }
        }
    }

    func importLibrary() {
        guard LibraryMutationPolicy.allowsLibraryImport(phase: libraryPhase, setupBusy: setupBusy, recording: isRecording, processing: processingID != nil, changingRecording: changingRecording, importingLibrary: importingLibrary, libraryImportPending: libraryImportPending, meetingCount: meetings.count) else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "Import Library"
        panel.message = "Quit the other Echo Voice installation, then choose its EchoVoice data folder. The source is preserved. Models remain installed separately. Restart this app after import."
        guard panel.runModal() == .OK, let source = panel.url else { return }
        let accessed = source.startAccessingSecurityScopedResource()
        importingLibrary = true
        let destination = paths
        Task {
            defer { importingLibrary = false; if accessed { source.stopAccessingSecurityScopedResource() } }
            do {
                try await Task.detached { try LibraryImport.stage(source: source, destination: destination) }.value
                libraryImportPending = true; status = "Library import prepared. Quit and reopen Echo Voice to finish."
            } catch { self.error = error.localizedDescription }
        }
    }

    func deleteSelected() async {
        if let id = selectedID, assetWorkBlocked(id) { return }
        guard let id = selectedID, id != recordingID, !redactionBusy,
              !pendingRedactionMeetings.contains(id), let store else { return }
        deletingMeetings.insert(id)
        defer { deletingMeetings.remove(id) }
        if processingID == id { processingTask?.cancel(); await processor?.cancel(); await processingTask?.value }
        stopPlayback(); player = nil
        do {
            try await mutationCoordinator.withLease(meetingID: id, access: .exclusive) {
                try await Task.detached { try store.deleteMeeting(id: id) }.value
            }
            selectedID = nil; reload(); selectedID = meetings.first?.id
        }
        catch {
            pendingMeetingDeletions = Set(store.deletionRecoveryIssues.map(\.meetingID))
            reload()
            if !meetings.contains(where: { $0.id == id }) { selectedID = meetings.first?.id }
            self.error = error.localizedDescription
        }
    }

    func play(at time: Double = 0, track: AudioTrack? = nil) {
        if let id = selectedID, assetWorkBlocked(id) { return }
        guard !isRecording, !redactionBusy, let id = selectedID,
              !pendingRedactionMeetings.contains(id), let store,
              selectedMeeting != nil else { return }
        do {
            let all = try store.chunks(meetingID: id)
            playbackTrack = track
            let chunks: [CapturedChunk]
            if let track {
                chunks = all.filter { $0.track == track }
            } else {
                chunks = all.filter { $0.track == .remote }
                    + (try store.microphoneTranscriptChunks(meetingID: id))
            }
            let speakerphoneChunks = try store.speakerphoneMicrophoneChunks(meetingID: id)
            let uncoveredMicrophone = AECCoverageAudit.uncovered(near: speakerphoneChunks, clean: all.filter { $0.track == .cleanMicrophone })
            if track == nil && !uncoveredMicrophone.isEmpty {
                status = "Conversation playback has missing cleaned microphone audio. Missing portions remain silent; raw microphone audio is available separately."
            }
            guard !chunks.isEmpty else { throw RuntimeError.service("This track has no saved audio. Choose another track.") }
            let player = try MeetingPlayer(directory: paths.meetingDirectory(id), chunks: chunks, audioAssets: store.audioAssets)
            player.rate = playbackRate; player.onError = { [weak self] message in self?.error = message }
            self.player?.stop(); self.player = player; try player.play(at: time); playing = true; playbackTime = time
        } catch { self.error = error.localizedDescription }
    }
    func stopPlayback() { player?.stop(); playing = false }
    func showEvidence(_ id: String) {
        if let meetingID = selectedID, let segment = try? store?.segment(meetingID: meetingID, versionID: activeTranscriptID, segmentID: id) {
            selectedTab = "Transcript"; play(at: segment.startTime, track: segment.track)
            Task { await transcriptList?.reveal(segmentID: id) }
            return
        }
        for version in transcriptVersions {
            if let meetingID = selectedID, let segment = try? store?.segment(meetingID: meetingID, versionID: version.id, segmentID: id) {
                status = "Playing evidence from an earlier transcript."; play(at: segment.startTime, track: segment.track); return
            }
        }
    }
    func shutdown() async {
        isShuttingDown = true
        await libraryOpenTask?.value
        queuedDownloads = []; setupTask?.cancel(); cancelPreparation(); await preparationTask?.value; if isRecording { await stopRecording(finalize: false) }; processingTask?.cancel(); await processor?.cancel(); await service.stop(); stopPlayback()
    }
    static let meetingAudioPermissionKey = "permission.meetingAudio"
    static let onboardingDismissedKey = "onboarding.dismissed"
    static let audibleLevel: Float = 0.001
    static func duration(_ seconds: Double) -> String {
        let minutes = max(0, Int((seconds / 60).rounded()))
        if minutes < 1 { return "<1 min" }
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }
    static func timestamp(_ seconds: Double) -> String { let value = max(0, Int(seconds)); return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) : String(format: "%02d:%02d", value / 60, value % 60) }
}
