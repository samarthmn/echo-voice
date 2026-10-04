import XCTest
import EchoCore

@MainActor
final class WorkspaceStateTests: XCTestCase {
    func testNotesDefaultOnlyAppliesOnceAndNeverOverridesAnExplicitTab() {
        let workspace = WorkspaceState()
        workspace.selectMeeting("first")
        workspace.resolveInitialTab(hasNotes: true, recording: false)
        XCTAssertEqual(workspace.tab, .notes)
        workspace.tab = .transcript
        workspace.resolveInitialTab(hasNotes: true, recording: false)
        XCTAssertEqual(workspace.tab, .transcript)
        workspace.selectMeeting("second")
        workspace.tab = .transcript // A search hit arrives before the detail fetch.
        workspace.resolveInitialTab(hasNotes: true, recording: false)
        XCTAssertEqual(workspace.tab, .transcript)
    }
    func testResumeRouteKeepsTheRequestedMeeting() {
        let workspace = WorkspaceState()
        workspace.presentation = .newMeeting(resumeID: "interrupted")
        workspace.selectMeeting("another")
        XCTAssertEqual(workspace.presentation, .newMeeting(resumeID: "interrupted"))
    }
}
