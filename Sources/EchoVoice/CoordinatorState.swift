import Foundation
import Observation
import EchoCore

@Observable @MainActor
final class RecordingState {
    var meetingID: String?
    var microphoneMuted = false
    var liveTranscriptionPolicy: LiveTranscriptionPolicy?
    var acousticMode: CaptureAcousticMode = .headphones
    var microphoneUID: String?
    var applicationID: String?
    var changing = false
    var paused = false
    var waitingForRemoteAudio = false
    var message = ""
}

@Observable @MainActor
final class ProcessingState {
    var activeMeetingID: String?
    var events: [String: ProcessingEvent] = [:]
    var queue: [QueuedProcessing] = []
}
