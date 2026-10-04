import SwiftUI
import EchoCore

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
