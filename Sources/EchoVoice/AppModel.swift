import Foundation
import SwiftUI
import AppKit
import AVFoundation
import EchoCore
import EchoCapture
import EchoRuntime
import EchoIntelligence

@MainActor
final class AppModel: ObservableObject {
    let paths: AppPaths
    var store: MeetingStore?
    let service: LocalService
    let installer: RuntimeInstaller
    let intelligence: LocalIntelligence
    let ollamaNotes: OllamaNotesClient
    var processor: MeetingProcessor?
    var redactor: RedactionCoordinator?
    let mutationCoordinator = MeetingMutationCoordinator()
    let capture: AudioCaptureController
    let recordingSession = RecordingSessionModel()
    let playbackModel = PlaybackModel()
    let workspace = WorkspaceState()
    let recording = RecordingState()
    let processing = ProcessingState()
    var processingEvents: [String: ProcessingEvent] { get { processing.events } set { processing.events = newValue } }
    var queuedProcessing: [QueuedProcessing] { get { processing.queue } set { processing.queue = newValue } }
    var inferenceHandoff: Task<Void, Never>?
    var liveStartTask: Task<Void, Never>?
    var processingGeneration = 0
    @Published var meetings: [Meeting] = []
    @Published var selectedID: String? {
        didSet {
            if oldValue != selectedID {
                workspace.selectMeeting(selectedID)
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
    @Published var transcriptList: TranscriptListModel?
    var displayedTranscriptKey: String?
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
    var recordingID: String? { get { recording.meetingID } set { recording.meetingID = newValue } }
    var microphoneMuted: Bool { get { recording.microphoneMuted } set { recording.microphoneMuted = newValue } }
    var liveTranscriptionPolicy: LiveTranscriptionPolicy? { get { recording.liveTranscriptionPolicy } set { recording.liveTranscriptionPolicy = newValue } }
    var acousticMode: CaptureAcousticMode { get { recording.acousticMode } set { recording.acousticMode = newValue } }
    var recordingMicrophoneUID: String? { get { recording.microphoneUID } set { recording.microphoneUID = newValue } }
    var recordingApplicationID: String? { get { recording.applicationID } set { recording.applicationID = newValue } }
    var showInputsPanel: Bool {
        get { if case .inputs = workspace.presentation { return true }; return false }
        set {
            if newValue, let id = recordingID { workspace.presentation = .inputs(meetingID: id) }
            else if !newValue, case .inputs = workspace.presentation { workspace.presentation = nil }
        }
    }
    @Published var redactionBusy = false
    @Published var pendingRedactionMeetings: Set<String> = []
    @Published var recoveringAssetMeetings: Set<String> = []
    @Published var damagedAssetMeetings: Set<String> = []
    @Published var deletingMeetings: Set<String> = []
    @Published var pendingMeetingDeletions: Set<String> = []
    var changingRecording: Bool { get { recording.changing } set { recording.changing = newValue } }
    var processingID: String? { get { processing.activeMeetingID } set { processing.activeMeetingID = newValue } }
    var isPaused: Bool { get { recording.paused } set { recording.paused = newValue } }
    var elapsed: Double { get { recordingSession.elapsed } set { recordingSession.elapsed = newValue } }
    var microphoneLevel: Float { get { recordingSession.microphoneLevel } set { recordingSession.microphoneLevel = newValue } }
    var remoteLevel: Float { get { recordingSession.remoteLevel } set { recordingSession.remoteLevel = newValue } }
    var waitingForRemoteAudio: Bool { get { recording.waitingForRemoteAudio } set { recording.waitingForRemoteAudio = newValue } }
    @Published var status = "Ready when you are"
    let issues = IssueCenter()
    var error: String? {
        get { issues.current?.message }
        set {
            if let newValue { issues.report(newValue, scope: .library) }
            else { issues.current = nil }
        }
    }
    var setupError: String? {
        get { if issues.current?.scope == .setup { return issues.current?.message }; return nil }
        set {
            if let newValue { issues.report(newValue, scope: .setup) }
            else if issues.current?.scope == .setup { issues.current = nil }
        }
    }
    var recordingError: String? {
        get { if issues.current?.scope == .recording { return issues.current?.message }; return nil }
        set {
            if let newValue { issues.report(newValue, scope: .recording) }
            else if issues.current?.scope == .recording { issues.current = nil }
        }
    }
    @Published var libraryRecovery: String?
    @Published var libraryPhase: LibraryOpenPhase = .opening
    var isShuttingDown = false
    var libraryOpenTask: Task<Void, Never>?
    var showNewMeeting: Bool {
        get { if case .newMeeting = workspace.presentation { return true }; return false }
        set {
            if newValue { workspace.presentation = .newMeeting(resumeID: nil) }
            else if case .newMeeting = workspace.presentation { workspace.presentation = nil }
        }
    }
    func resumeMeeting(_ id: String) { workspace.presentation = .newMeeting(resumeID: id) }
    @Published var health: ServiceHealth?
    @Published var setupBusy = false
    @Published var setupProgress = "Install local models to get started."
    @Published var runtimeChecked = false
    @Published var activeDownload: ModelDownload?
    @Published var stagedDownloads: [StagedModelDownload] = []
    var activationTask: Task<Void, Never>?
    @Published var queuedDownloads: [ModelDownload] = []
    @Published var microphonePermission = CapturePermissions.microphoneState
    @Published var meetingAudioPermission = PermissionState(rawValue: UserDefaults.standard.string(forKey: AppModel.meetingAudioPermissionKey) ?? "") ?? .notDetermined
    var showOnboarding: Bool {
        get { workspace.presentation == .setup }
        set {
            if newValue { workspace.presentation = .setup }
            else if workspace.presentation == .setup { workspace.presentation = nil }
        }
    }
    @Published var ollamaModels: [OllamaModel] = []
    @Published var ollamaStatus = "Ollama has not been checked."
    @Published var ollamaChecked = false
    @Published var refreshingOllama = false
    @Published var testingInputs = false
    @Published var cancellingPreparation = false
    @Published var inputTestPassed = false
    @Published var searchQuery = "" { didSet { search() } }
    @Published var searchResults: [SearchHit] = []
    var selectedTab: ReviewTab {
        get { workspace.tab }
        set { workspace.tab = newValue }
    }
    @Published var activeTranscriptID = ""
    @Published var annotations: [TranscriptAnnotation] = []
    @Published var followPlayback = true
    @Published var playbackTrack: AudioTrack?
    @Published var showOnlyHighlights = false
    @Published var transcriptVersions: [TranscriptVersion] = []
    @Published var readyTranscriptID: String?
    @Published var selectedConfiguration: ProcessingConfiguration?
    @Published var groupingRuns: [SpeakerGroupingRun] = []
    var speakerTurnIndices: [String: SpeakerTurnIndex] = [:]
    @Published var availableTracks: Set<AudioTrack> = []
    @Published var settingsPage = SettingsPage.models
    @Published var settingsModelRole: ModelRole = .speech
    @Published var importingLibrary = false
    @Published var libraryImportPending = false
    var playing: Bool { get { playbackModel.playing } set { playbackModel.playing = newValue } }
    @Published var playbackRate: Float = 1 { didSet { player?.rate = playbackRate } }
    var playbackTime: Double { get { playbackModel.time } set { playbackModel.time = newValue } }
    var searchTask: Task<Void, Never>?
    var detailTask: Task<Void, Never>?
    var detailGeneration = 0
    var pendingDetailRefresh = false
    var clock: Timer?
    var lastElapsedSecond = -1
    var lastMicrophoneMeterAt = -Double.infinity
    var lastRemoteMeterAt = -Double.infinity
    var refreshTask: Task<Void, Never>?
    var processingTask: Task<Void, Never>?
    var compactionTask: Task<Void, Never>?
    var exportTask: Task<Void, Never>?
    var setupTask: Task<Void, Never>?
    var player: MeetingPlayer?
    var activationObserver: NSObjectProtocol?
    var preparationTask: Task<Void, Never>?
    var inputTestCapture: AudioCaptureController?
    var stoppingRecording = false

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

    func shutdown() async {
        isShuttingDown = true
        await libraryOpenTask?.value
        queuedDownloads = []; setupTask?.cancel(); activationTask?.cancel(); cancelPreparation(); await preparationTask?.value; if isRecording { await stopRecording(finalize: false) }; processingTask?.cancel(); await processor?.cancel(); await service.stop(); stopPlayback()
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
