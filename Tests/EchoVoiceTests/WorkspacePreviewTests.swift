import AppKit
import SwiftUI
import XCTest
import EchoCore

/// Opt-in, synthetic documentation previews. No microphone, meeting app, or model is started.
@MainActor
final class WorkspacePreviewTests: XCTestCase {
    func testRenderSyntheticWorkspaceAtMinimumSize() async throws {
        guard let destination = ProcessInfo.processInfo.environment["ECHO_UI_PREVIEW_ROOT"], !destination.isEmpty else {
            throw XCTSkip("Set ECHO_UI_PREVIEW_ROOT to a directory under the project's tmp to render previews.")
        }
        let root = URL(fileURLWithPath: destination)
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["ECHO_TEST_ROOT"])
        let projectTmp = URL(fileURLWithPath: base).deletingLastPathComponent().standardizedFileURL.path + "/"
        XCTAssertTrue(root.standardizedFileURL.path.hasPrefix(projectTmp))
        guard root.standardizedFileURL.path.hasPrefix(projectTmp) else { return }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = AppPaths(root: root.appendingPathComponent("library"))
        let store = try MeetingStore(paths: paths)
        let start = Date(timeIntervalSince1970: 1_790_682_600)
        try store.createMeeting(Meeting(id: "preview-design", title: "Product design review", startedAt: start,
            endedAt: start.addingTimeInterval(245), state: .ready, language: "en", sourceName: "Design team",
            usesEchoCancellation: false, transcriptRevision: 0))
        let lines = [
            "Let's make the first recording easy to start. People should see their microphone and meeting application before they begin.",
            "The consent checkbox stays next to the recording action. We should explain what is missing beside that button.",
            "When a meeting is finished, open its notes first. A link to evidence should take us straight to the supporting transcript.",
            "Keep recording controls visible while we review another meeting. Stop must always control the active recording.",
            "I'll check the smaller window layout and keyboard navigation before our next review."
        ]
        let segments = lines.enumerated().map { index, text in
            TranscriptSegment(id: "preview-passage-\(index)", meetingID: "preview-design", windowID: "preview-window",
                track: .remote, startTime: Double(index * 45), endTime: Double(index * 45 + 35), text: text,
                speakerID: nil, isUncertain: false, isProvisional: false, isEdited: false)
        }
        try store.replaceSegments(meetingID: "preview-design", windowID: "preview-window", segments: segments, isFinal: true)
        let revision = try XCTUnwrap(store.meeting(id: "preview-design")).transcriptRevision
        try store.saveNotes(MeetingNotes(id: "preview-notes", meetingID: "preview-design", createdAt: start.addingTimeInterval(245),
            transcriptRevision: revision,
            summary: [NoteItem(id: "summary", text: "The team reviewed a simpler recording setup and a focused meeting workspace.", evidenceIDs: [segments[0].id, segments[2].id])],
            decisions: [NoteItem(id: "decision", text: "Open completed meetings to notes and keep recording controls visible throughout the workspace.", evidenceIDs: [segments[2].id, segments[3].id])],
            actionItems: [NoteItem(id: "action", text: "Check the smaller window layout and keyboard navigation before the next review.", evidenceIDs: [segments[4].id])],
            isEdited: false, isPartial: false))
        let previous = ProcessInfo.processInfo.environment["ECHO_DATA_ROOT"]
        setenv("ECHO_DATA_ROOT", paths.root.path, 1)
        let model = AppModel()
        if let previous { setenv("ECHO_DATA_ROOT", previous, 1) } else { unsetenv("ECHO_DATA_ROOT") }
        for _ in 0..<300 {
            if model.runtimeChecked && !model.notes.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        model.workspace.presentation = nil
        XCTAssertEqual(model.selectedTab, .notes)
        try await render(ContentView().environmentObject(model), size: .init(width: 960, height: 640), appearance: .aqua, to: root.appendingPathComponent("workspace-light.png"))
        try await render(ContentView().environmentObject(model), size: .init(width: 960, height: 640), appearance: .darkAqua, to: root.appendingPathComponent("workspace-dark.png"))
        model.selectedTab = .transcript
        try await render(ContentView().environmentObject(model), size: .init(width: 960, height: 640), appearance: .aqua, to: root.appendingPathComponent("transcript-light.png"))
        try await render(StartMeetingView().environmentObject(model), size: .init(width: 620, height: 580), appearance: .aqua, to: root.appendingPathComponent("new-meeting-light.png"))
        await model.shutdown()
    }

    private func render<V: View>(_ view: V, size: NSSize, appearance: NSAppearance.Name, to url: URL) async throws {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: .init(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.setContentSize(size)
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(350))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: url)
        window.orderOut(nil)
        window.contentView = nil
    }
}
