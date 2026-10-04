import Foundation
import Observation
import EchoCore
import EchoCapture

// The singleton workspace owns navigation, independently of shared capture/services.
enum ReviewTab: String, CaseIterable, Identifiable {
    case notes = "Notes", transcript = "Transcript"
    var id: String { rawValue }
}
enum WorkspacePresentation: Equatable, Identifiable {
    case newMeeting(resumeID: String?), setup, inputs(meetingID: String)
    var id: String {
        switch self {
        case .newMeeting(let id): return "record-" + (id ?? "new")
        case .setup: return "setup"
        case .inputs(let id): return "inputs-" + id
        }
    }
}
@Observable @MainActor
final class WorkspaceState {
    var presentation: WorkspacePresentation?
    var inspectorVisible = false
    private(set) var meetingID: String?
    private var initialTabPending = true
    var tab: ReviewTab = .transcript { didSet { initialTabPending = false } }
    func selectMeeting(_ id: String?) {
        guard meetingID != id else { return }
        meetingID = id
        tab = .transcript
        initialTabPending = true
    }
    func resolveInitialTab(hasNotes: Bool, recording: Bool) {
        guard initialTabPending else { return }
        tab = hasNotes && !recording ? .notes : .transcript
    }
}

struct RecordingRequest {
    var title: String
    var application: AudioSource?
    var microphone: MicrophoneDevice?
    var singleSource: Bool
    var acousticMode: CaptureAcousticMode
    var consent: Bool
    var speechModel: SpeechRecognitionModel
    var resumeID: String?
    var mode: RecordingMode
    var microphoneMuted: Bool
    var liveTranscription: Bool
    var speakerModelID: String?
}
