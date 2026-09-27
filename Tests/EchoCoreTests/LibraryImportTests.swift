import XCTest
import CryptoKit
@testable import EchoCore

final class LibraryImportTests: XCTestCase {
    func testImportPreservesReviewStateRawAudioAndDestinationModels() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ECHO_TEST_ROOT"] ?? FileManager.default.currentDirectoryPath + "/tmp/tests").appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = AppPaths(root: root.appendingPathComponent("source"))
        let target = AppPaths(root: root.appendingPathComponent("target"))
        let sourceStore = try MeetingStore(paths: source)
        let targetStore = try MeetingStore(paths: target)
        try sourceStore.createMeeting(.init(id: "meeting", title: "Fictional discussion", startedAt: Date(timeIntervalSince1970: 100), endedAt: Date(timeIntervalSince1970: 105), state: .ready, language: "en", sourceName: "Room microphone", usesEchoCancellation: false, transcriptRevision: 0, speechModel: .parakeet, recordingMode: .inPerson))

        let audio = Data("synthetic raw audio bytes".utf8)
        let audioURL = source.meetingDirectory("meeting").appendingPathComponent("audio/raw.caf")
        try FileManager.default.createDirectory(at: audioURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try audio.write(to: audioURL)
        let chunk = CapturedChunk(id: "raw", meetingID: "meeting", epochID: "epoch", track: .microphone, relativePath: "audio/raw.caf", startTime: 0, duration: 1, sampleRate: 16_000, frameCount: 16_000, sha256: SHA256.hash(data: audio).map { String(format: "%02x", $0) }.joined())
        try sourceStore.addChunk(chunk)

        let selection = ModelSelection(id: "parakeet", revision: "fixture-revision")
        let configuration = ProcessingConfiguration(speech: selection)
        try sourceStore.setConfiguration(meetingID: "meeting", configuration: configuration)
        try sourceStore.setPreference("defaultSpeechModel", value: selection)
        try sourceStore.saveVocabulary([VocabularyEntry(id: "term", spelling: "Echo Voice")])
        let segment = TranscriptSegment(id: "spoken", meetingID: "meeting", windowID: "window", track: .microphone, startTime: 0, endTime: 1, text: "Original words", speakerID: nil, isUncertain: false, isProvisional: false, isEdited: false)
        try sourceStore.upsertSegments([segment])
        try sourceStore.editSegment(id: segment.id, text: "Corrected words")
        let revision = try XCTUnwrap(sourceStore.meeting(id: "meeting")).transcriptRevision
        var notes = MeetingNotes(id: "notes", meetingID: "meeting", createdAt: Date(timeIntervalSince1970: 106), transcriptRevision: revision, summary: [NoteItem(id: "summary", text: "Reviewed summary", evidenceIDs: [segment.id])], decisions: [], actionItems: [], isEdited: true, isPartial: false)
        notes.model = ModelSelection(id: "local-notes", revision: "fixture-revision")
        notes.transcriptVersionID = "legacy-meeting"
        try sourceStore.saveNotes(notes)
        let annotation = TranscriptAnnotation(id: "bookmark", meetingID: "meeting", kind: .bookmark, transcriptVersionID: "legacy-meeting", segmentID: segment.id, track: .microphone, startTime: 0.25, label: "Review")
        try sourceStore.saveAnnotation(annotation)
        let version = TranscriptVersion(id: "version", meetingID: "meeting", status: .ready, configuration: configuration, audioFingerprint: "fixture-audio")
        try sourceStore.saveTranscriptVersion(version)

        let installedModel = target.modelsURL.appendingPathComponent("existing-model/weights.bin")
        try FileManager.default.createDirectory(at: installedModel.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("keep model".utf8).write(to: installedModel)
        _ = targetStore
        try LibraryImport.stage(source: source.root, destination: target)
        try LibraryImport.activatePending(destination: target)

        let imported = try MeetingStore(paths: target)
        XCTAssertEqual(try imported.meeting(id: "meeting")?.recordingMode, .inPerson)
        XCTAssertEqual(try imported.meeting(id: "meeting")?.recognitionModel, .parakeet)
        XCTAssertEqual(try imported.chunks(meetingID: "meeting"), [chunk])
        XCTAssertEqual(try Data(contentsOf: target.meetingDirectory("meeting").appendingPathComponent(chunk.relativePath)), audio)
        XCTAssertEqual(try imported.segments(meetingID: "meeting").first?.text, "Corrected words")
        XCTAssertEqual(try imported.notes(meetingID: "meeting"), [notes])
        XCTAssertEqual(try imported.annotations(meetingID: "meeting"), [annotation])
        XCTAssertEqual(try imported.transcriptVersions(meetingID: "meeting"), [version])
        XCTAssertEqual(try imported.configuration(meetingID: "meeting"), configuration)
        XCTAssertEqual(try imported.preference("defaultSpeechModel", as: ModelSelection.self), selection)
        XCTAssertEqual(try imported.vocabulary().map(\.spelling), ["Echo Voice"])
        XCTAssertEqual(try Data(contentsOf: installedModel), Data("keep model".utf8))
        XCTAssertEqual(try sourceStore.meetings().count, 1)
    }

    func testImportPreservesSourceAndResumesInterruptedActivation() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ECHO_TEST_ROOT"] ?? FileManager.default.currentDirectoryPath + "/tmp/tests").appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = AppPaths(root: root.appendingPathComponent("source"))
        let target = AppPaths(root: root.appendingPathComponent("target"))
        do {
            let store = try MeetingStore(paths: source)
            try store.createMeeting(.init(id: "meeting", title: "Fictional discussion", startedAt: Date(), endedAt: nil, state: .ready, language: "en", sourceName: "Room microphone", usesEchoCancellation: false, transcriptRevision: 0, recordingMode: .inPerson))
            _ = try MeetingStore(paths: target)
        }
        enum SimulatedCrash: Error { case interrupted }
        XCTAssertThrowsError(try LibraryImport.stage(source: source.root, destination: target, checkpoint: { _ in throw SimulatedCrash.interrupted }))
        XCTAssertTrue(LibraryImport.hasPending(destination: target))
        XCTAssertThrowsError(try LibraryImport.activatePending(destination: target, checkpoint: { step in if step == "old-moved" { throw SimulatedCrash.interrupted } }))
        try LibraryImport.activatePending(destination: target)
        XCTAssertEqual(try MeetingStore(paths: target).meetings().first?.recordingMode, .inPerson)
        XCTAssertEqual(try MeetingStore(paths: source).meetings().count, 1)
        XCTAssertThrowsError(try LibraryImport.stage(source: source.root, destination: target))
    }

    func testImportRejectsMediaSymlinks() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ECHO_TEST_ROOT"] ?? FileManager.default.currentDirectoryPath + "/tmp/tests").appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = AppPaths(root: root.appendingPathComponent("source"))
        let target = AppPaths(root: root.appendingPathComponent("target"))
        _ = try MeetingStore(paths: source); _ = try MeetingStore(paths: target)
        try FileManager.default.createSymbolicLink(at: source.meetingsURL.appendingPathComponent("escape"), withDestinationURL: root)
        XCTAssertThrowsError(try LibraryImport.stage(source: source.root, destination: target))
        XCTAssertFalse(LibraryImport.hasPending(destination: target))
    }
}
