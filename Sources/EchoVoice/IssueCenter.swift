import Foundation
import Observation

struct UserFacingIssue: Identifiable, Equatable {
    enum Scope: Equatable { case library, setup, recording, meeting(String) }
    let id = UUID()
    let scope: Scope
    let message: String
}

@Observable @MainActor
final class IssueCenter {
    var current: UserFacingIssue?
    func report(_ message: String, scope: UserFacingIssue.Scope) {
        current = UserFacingIssue(scope: scope, message: message)
    }
}
