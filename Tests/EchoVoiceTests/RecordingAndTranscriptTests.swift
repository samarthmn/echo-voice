import AppKit
import SwiftUI
import XCTest
@testable import EchoCore
@testable import EchoCapture

@MainActor
final class RecordingAndTranscriptTests: XCTestCase {
    func testPlaybackScheduleTerminatesAtFractionalSampleBoundary() throws {
        let end = 30.123456789
        var cursor = 22.0
        var windows = 0
        while let window = PlaybackBufferWindow(start: cursor, end: end) {
            XCTAssertGreaterThan(window.end, cursor)
            XCTAssertLessThanOrEqual(window.duration, 2)
            cursor = window.end
            windows += 1
            if windows > 6 { XCTFail("Playback must reach the end without a zero-frame loop"); break }
        }
        XCTAssertEqual(cursor, end)
        XCTAssertEqual(windows, 5)
        let tail = try XCTUnwrap(PlaybackBufferWindow(start: end - 0.000001, end: end))
        XCTAssertEqual((tail.duration * 48_000).rounded(), 0)
        XCTAssertNil(PlaybackBufferWindow(start: tail.end, end: end))
    }

    private func fixture(capture: AudioCaptureController? = nil) async throws -> (URL, AppModel) {
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["ECHO_TEST_ROOT"])
        let root = URL(fileURLWithPath: base).appendingPathComponent("app-review-\(UUID().uuidString)")
        let store = try MeetingStore(paths: AppPaths(root: root))
        try store.createMeeting(Meeting(id: "meeting", title: "Synthetic", startedAt: Date(), endedAt: Date(),
                                        state: .ready, language: "en", sourceName: "Fixture",
                                        usesEchoCancellation: false, transcriptRevision: 0))
        try store.replaceSegments(meetingID: "meeting", windowID: "window", segments: [
            TranscriptSegment(id: "passage", meetingID: "meeting", windowID: "window", track: .remote,
                              startTime: 0, endTime: 1, text: "Synthetic passage", speakerID: nil,
                              isUncertain: false, isProvisional: false, isEdited: false)
        ], isFinal: true)
        let previous = ProcessInfo.processInfo.environment["ECHO_DATA_ROOT"]
        setenv("ECHO_DATA_ROOT", root.path, 1)
        let model = AppModel(capture: capture)
        if let previous { setenv("ECHO_DATA_ROOT", previous, 1) } else { unsetenv("ECHO_DATA_ROOT") }
        for _ in 0..<300 {
            if model.libraryPhase == .ready && model.recoveringAssetMeetings.isEmpty && model.runtimeChecked { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.libraryPhase, .ready)
        return (root, model)
    }

    private func recordingFixture() async throws -> (URL, AppModel, ControlledDevices) {
        let devices = try ControlledDevices()
        let capture = AudioCaptureController(devices: devices.provider)
        let (root, model) = try await fixture(capture: capture)
        try model.store?.setCaptureSessionSettings(meetingID: "meeting", settings: .init(
            microphoneUID: devices.mic.id, applicationID: devices.app.id,
            microphoneMuted: false, acousticMode: .headphones))
        try await capture.start(.init(meetingID: "meeting", meetingDirectory: root.appendingPathComponent("capture"),
                                      application: devices.app, microphone: devices.mic, allowSingleSource: false),
                                onEvent: { _ in })
        model.recordingID = "meeting"
        model.recordingMicrophoneUID = devices.mic.id
        model.recordingApplicationID = devices.app.id
        return (root, model, devices)
    }

    func testProcessingRequestQueuesWhileAnotherMeetingRecords() async throws {
        let (root, model) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        model.recordingID = "another"
        model.processMeeting("meeting")
        XCTAssertNil(model.processingID)
        XCTAssertEqual(try model.store?.processingQueue().map(\.meetingID), ["meeting"])
        model.recordingID = nil
        await model.shutdown()
    }

    func testStopWithoutImmediateProcessingPersistsQueueForRelaunch() async throws {
        let (root, model) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        model.recordingID = "meeting"
        await model.stopRecording(finalize: false)
        XCTAssertEqual(try model.store?.processingQueue().map(\.meetingID), ["meeting"])
        XCTAssertEqual(try model.store?.meeting(id: "meeting")?.state, .finalizing)
        await model.shutdown()
    }

    func testStopWakesStagedActivationEvenWhenSpeechCannotProcess() async throws {
        let (root, model) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        model.recordingID = "meeting"
        model.stagedDownloads = [.init(id: "parakeet", makeDefault: false)]
        model.activateStagedDownloads()
        XCTAssertNil(model.activationTask)
        await model.stopRecording()
        XCTAssertNotNil(model.activationTask, "Stop must activate staged weights before a model-blocked queue can run")
        XCTAssertTrue(model.setupBusy)
        XCTAssertEqual(try model.store?.processingQueue().map(\.meetingID), ["meeting"])
        await model.shutdown()
    }

    func testModelMutationWaitsForInferenceHandoff() async throws {
        let (root, model) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        model.inferenceHandoff = Task {}
        XCTAssertFalse(model.modelChangesAllowed)
        model.stagedDownloads = [.init(id: "parakeet", makeDefault: false)]
        model.activateStagedDownloads()
        XCTAssertNil(model.activationTask)
        model.inferenceHandoff = nil
        XCTAssertTrue(model.modelChangesAllowed)
        await model.shutdown()
    }

    func testQueueUsesReviewedVersionModelsWithoutRequiringOriginalSpeech() async throws {
        let (root, model) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try XCTUnwrap(model.store)
        let configuration = ProcessingConfiguration(speech: .init(id: "asr", revision: "old"), notes: .init(id: "gemma", revision: "pinned"))
        var version = TranscriptVersion(meetingID: "meeting", configuration: configuration, audioFingerprint: "fixture")
        version.status = .ready
        try store.saveTranscriptVersion(version)
        try store.activateTranscriptVersion(version.id, meetingID: "meeting")
        XCTAssertTrue(try store.finalizationContext(meetingID: "meeting").reusesTranscript)
        XCTAssertEqual(model.missingProcessingModels("meeting"), [model.catalog?.model("gemma")?.displayName ?? "gemma"])
        await model.shutdown()
    }

    func testNotesDefaultDoesNotStealAnExplicitTranscriptSelection() async throws {
        let (root, model) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try model.store?.saveNotes(MeetingNotes(id: "notes", meetingID: "meeting", createdAt: Date(), transcriptRevision: 0,
            summary: [], decisions: [], actionItems: [], isEdited: false, isPartial: false))
        model.selectedID = nil
        model.selectedID = "meeting"
        for _ in 0..<100 where model.notes.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.selectedTab, .notes)
        model.selectedTab = .transcript
        model.reloadDetail()
        for _ in 0..<100 where model.detailTask != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.selectedTab, .transcript)
        await model.shutdown()
    }

    func testListeningSetupTargetsRecordingWhileAnotherMeetingIsSelected() async throws {
        let (root, model, _) = try await recordingFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var other = Meeting(id: "other", title: "Room", startedAt: Date(), endedAt: Date(), state: .ready,
            language: "en", sourceName: "Room", usesEchoCancellation: false, transcriptRevision: 0)
        other.recordingMode = .inPerson
        try model.store?.createMeeting(other)
        model.reload(); model.selectedID = "other"
        await model.setAcousticMode(.speakerphone)
        XCTAssertEqual(model.acousticMode, .speakerphone)
        XCTAssertEqual(try model.store?.captureSessionSettings(meetingID: "meeting").acousticMode, .speakerphone)
        await model.shutdown()
    }

    func testMuteDuringAcousticModeTransitionRemainsMuted() async throws {
        let (root, model, devices) = try await recordingFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        devices.blockNextApplication()
        let application = Task { try await model.capture.changeApplication(sourceID: devices.app.id) }
        let started = await semaphoreWait(devices.applicationStarted)
        XCTAssertTrue(started)
        let mode = Task { await model.setAcousticMode(.speakerphone) }
        for _ in 0..<50 {
            if model.capture.microphoneMuted { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let mute = Task { await model.setMicrophoneMuted(true) }
        try await Task.sleep(for: .milliseconds(20))
        devices.releaseApplication.signal()
        try await application.value
        await mode.value
        await mute.value
        XCTAssertTrue(model.capture.microphoneMuted)
        XCTAssertTrue(model.microphoneMuted)
        XCTAssertTrue(try XCTUnwrap(model.store).captureSessionSettings(meetingID: "meeting").microphoneMuted)
        XCTAssertEqual(devices.microphoneOpenCount, 1)
        await model.shutdown()
    }

    func testMuteDuringAcousticModeMicrophoneOpeningPersistsActualState() async throws {
        let (root, model, devices) = try await recordingFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        devices.blockNextMicrophone()
        let mode = Task { await model.setAcousticMode(.speakerphone) }
        let started = await semaphoreWait(devices.microphoneStarted)
        XCTAssertTrue(started)
        let mute = Task { await model.setMicrophoneMuted(true) }
        try await Task.sleep(for: .milliseconds(20))
        devices.releaseMicrophone.signal()
        await mute.value
        await mode.value
        XCTAssertTrue(model.capture.microphoneMuted)
        XCTAssertTrue(model.microphoneMuted)
        XCTAssertTrue(try XCTUnwrap(model.store).captureSessionSettings(meetingID: "meeting").microphoneMuted)
        XCTAssertFalse(model.capture.recordingFormats.contains { $0.track == .microphone })
        await model.shutdown()
    }

    func testAcousticModeChangeRestartsOnlyUnmutedMicrophone() async throws {
        let (root, model, devices) = try await recordingFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.setAcousticMode(.speakerphone)
        XCTAssertEqual(devices.microphoneOpenCount, 2)
        XCTAssertFalse(model.capture.microphoneMuted)
        XCTAssertEqual(try XCTUnwrap(model.store).captureSessionSettings(meetingID: "meeting").acousticMode, .speakerphone)
        await model.setMicrophoneMuted(true)
        await model.setAcousticMode(.headphones)
        XCTAssertEqual(devices.microphoneOpenCount, 2, "A setup change must not open an intentionally muted input")
        XCTAssertTrue(model.microphoneMuted)
        let settings = try XCTUnwrap(model.store).captureSessionSettings(meetingID: "meeting")
        XCTAssertTrue(settings.microphoneMuted)
        XCTAssertEqual(settings.acousticMode, .headphones)
        await model.shutdown()
    }

    func testStopIsHonoredWhilePauseOrResumeIsChangingRecording() async throws {
        let (root, model) = try await fixture()
        model.recordingID = "meeting"
        model.changingRecording = true
        await model.stopRecording(finalize: false)
        XCTAssertNil(model.recordingID)
        XCTAssertFalse(model.changingRecording)
        await model.shutdown()
        try? FileManager.default.removeItem(at: root)
    }

    func testIdleTranscriptAppearsAfterAsynchronousRowsArrive() async throws {
        let (root, model) = try await fixture()
        let list = try XCTUnwrap(model.transcriptList)
        list.reset()
        let meeting = try XCTUnwrap(model.selectedMeeting)
        let host = NSHostingView(rootView: MeetingDetailView(meeting: meeting,
            playbackModel: model.playbackModel).environmentObject(model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        XCTAssertNil(table(in: host))
        await list.load(meetingID: meeting.id, versionID: model.activeTranscriptID)
        for _ in 0..<50 {
            host.layoutSubtreeIfNeeded()
            if table(in: host) != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(table(in: host)?.numberOfRows, 1)
        window.contentView = nil
        await model.shutdown()
        try? FileManager.default.removeItem(at: root)
    }

    private func table(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap { self.table(in: $0) }.first
    }
}
