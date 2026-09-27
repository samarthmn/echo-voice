import Foundation
import Combine
import EchoCore

@MainActor
final class RecordingSessionModel: ObservableObject {
    @Published var elapsed: Double = 0
    @Published var microphoneLevel: Float = 0
    @Published var remoteLevel: Float = 0
}

@MainActor
final class PlaybackModel: ObservableObject {
    @Published var playing = false
    @Published var time: Double = 0
}
