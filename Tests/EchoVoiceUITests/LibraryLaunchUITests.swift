import Foundation
import XCTest
import EchoCore

final class LibraryLaunchUITests: XCTestCase {
    private func launch(seed: Bool = false) throws -> (XCUIApplication, URL) {
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["ECHO_TEST_ROOT"])
        let root = URL(fileURLWithPath: base).appendingPathComponent("ux-ui-\(UUID().uuidString)")
        if seed {
            let store = try MeetingStore(paths: AppPaths(root: root))
            try store.createMeeting(Meeting(id: "synthetic", title: "Design Review", startedAt: Date(), endedAt: Date(),
                state: .ready, language: "en", sourceName: "Synthetic", usesEchoCancellation: false, transcriptRevision: 0))
            try store.saveNotes(MeetingNotes(id: "notes", meetingID: "synthetic", createdAt: Date(), transcriptRevision: 0,
                summary: [NoteItem(id: "summary", text: "Review the new meeting workspace.", evidenceIDs: [])],
                decisions: [], actionItems: [], isEdited: false, isPartial: false))
        }
        let app = XCUIApplication()
        app.launchEnvironment["ECHO_DATA_ROOT"] = root.path
        app.launchArguments = ["-onboarding.dismissed", "YES"]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        return (app, root)
    }
    func testLibraryShellOpensWithAnIsolatedEmptyLibrary() throws {
        let (app, root) = try launch()
        defer { app.terminate(); try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(app.buttons["new-meeting"].waitForExistence(timeout: 10))
    }
    func testNewMeetingRequiresConsentAndCanBeCancelled() throws {
        let (app, root) = try launch()
        defer { app.terminate(); try? FileManager.default.removeItem(at: root) }
        let newMeeting = app.buttons["new-meeting"]
        XCTAssertTrue(newMeeting.waitForExistence(timeout: 10))
        let ready = NSPredicate(format: "enabled == true")
        expectation(for: ready, evaluatedWith: newMeeting)
        waitForExpectations(timeout: 15)
        newMeeting.click()
        let start = app.buttons["start-recording"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertFalse(start.isEnabled)
        XCTAssertTrue(app.checkBoxes["recording-consent"].exists)
        app.buttons["Cancel"].click()
        XCTAssertFalse(start.exists)
    }
    func testSavedMeetingOpensNotesAndInspector() throws {
        let (app, root) = try launch(seed: true)
        defer { app.terminate(); try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(app.staticTexts["Review the new meeting workspace."].waitForExistence(timeout: 15))
        app.buttons["Meeting Details"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["Transcript History"].waitForExistence(timeout: 5))
        app.segmentedControls["review-tabs"].buttons["Transcript"].click()
        XCTAssertFalse(app.staticTexts["Review the new meeting workspace."].exists)
        app.segmentedControls["review-tabs"].buttons["Notes"].click()
        XCTAssertTrue(app.staticTexts["Review the new meeting workspace."].exists)
    }
}
