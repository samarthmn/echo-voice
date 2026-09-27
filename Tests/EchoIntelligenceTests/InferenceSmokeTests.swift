import XCTest
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import EchoCore
@testable import EchoIntelligence

/// Opt-in real model tests. Normal CI does not silently download model weights.
final class InferenceSmokeTests: XCTestCase {
    private func engine() throws -> LocalIntelligence {
        guard let path = ProcessInfo.processInfo.environment["ECHO_MODEL_TEST_ROOT"], !path.isEmpty, !path.contains("$(") else {
            throw XCTSkip("Set ECHO_MODEL_TEST_ROOT to an explicitly provisioned models directory")
        }
        let manifest = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("service/models.json")
        return LocalIntelligence(modelsURL: URL(fileURLWithPath: path), manifestURL: manifest)
    }

    func testRealNotesCiteSuppliedTranscriptAndLeaveUnknownAttributionsBlank() async throws {
        let intelligence = try engine()
        let meeting = Meeting(id: "fixture", title: "Planning fixture", startedAt: Date(), endedAt: Date(), state: .finalizing, language: "en", sourceName: "Synthetic fixture", usesEchoCancellation: false, transcriptRevision: 0)
        let statements = [
            "We have agreed to keep the launch date on October 12.",
            "The documentation needs an update. We have not assigned an owner or a deadline for that work.",
            "We discussed a possible redesign, but made no decision about it.",
        ]
        let segments = statements.enumerated().map { index, text in
            TranscriptSegment(id: "s\(index)", meetingID: meeting.id, windowID: "w0", track: .remote, startTime: Double(index * 5), endTime: Double(index * 5 + 4), text: text, speakerID: nil, isUncertain: true, isProvisional: false, isEdited: false)
        }
        let notes = try await intelligence.generateNotes(meeting: meeting, segments: segments)
        let items = notes.summary + notes.decisions + notes.actionItems
        XCTAssertFalse(items.isEmpty)
        for item in items {
            XCTAssertTrue(EvidenceValidator.isSupported(item.evidenceIDs, allowed: Set(segments.map(\.id))))
            XCTAssertNil(item.owner)
            if item.evidenceIDs == ["s1"] { XCTAssertNil(item.dueDate) }
        }
        await intelligence.releaseCache()
    }

    func testRealNotesResolveTwentyTwoLongStorageIDs() async throws {
        let intelligence = try engine()
        let meeting = Meeting(id: "long-citations", title: "Planning fixture", startedAt: Date(), endedAt: Date(), state: .finalizing, language: "en", sourceName: "Synthetic fixture", usesEchoCancellation: false, transcriptRevision: 0)
        let statements = [
            "We agreed to keep the launch on October 12.",
            "The documentation needs an update, but no owner or deadline has been assigned.",
            "We discussed a possible redesign and did not make a decision about it.",
        ]
        let segments = (0..<22).map { index in
            TranscriptSegment(id: String(format: "%064x", index), meetingID: meeting.id, windowID: "w0", track: .remote, startTime: Double(index * 5), endTime: Double(index * 5 + 4), text: statements[index % statements.count], speakerID: nil, isUncertain: true, isProvisional: false, isEdited: false)
        }
        let notes = try await intelligence.generateNotes(meeting: meeting, segments: segments)
        let items = notes.summary + notes.decisions + notes.actionItems
        XCTAssertFalse(items.isEmpty)
        XCTAssertFalse(notes.isPartial)
        for item in items {
            XCTAssertTrue(EvidenceValidator.isSupported(item.evidenceIDs, allowed: Set(segments.map(\.id))))
            XCTAssertTrue(item.evidenceIDs.allSatisfy { $0.count == 64 })
            XCTAssertNil(item.owner)
        }
        await intelligence.releaseCache()
    }

    func testRealOllamaNotesUseInstalledModelAndCiteSyntheticTranscript() async throws {
        guard let name = ProcessInfo.processInfo.environment["ECHO_OLLAMA_TEST_MODEL"], !name.isEmpty, !name.contains("$(") else {
            throw XCTSkip("Set ECHO_OLLAMA_TEST_MODEL to an installed local Ollama generation model")
        }
        let client = OllamaNotesClient()
        let available = try await client.models()
        let model = try XCTUnwrap(available.first { $0.name == name })
        let selection = ModelSelection(id: model.name, revision: model.digest, provider: .ollama)
        let meeting = Meeting(id: "ollama-fixture", title: "Synthetic planning fixture", startedAt: Date(), endedAt: Date(), state: .finalizing, language: "en", sourceName: "Synthetic fixture", usesEchoCancellation: false, transcriptRevision: 0)
        let statements = ["The team agreed to send the draft on Friday.", "No owner was assigned for the draft."]
        let segments = statements.enumerated().map { index, text in
            TranscriptSegment(id: "synthetic-\(index)", meetingID: meeting.id, windowID: "synthetic-window", track: .remote, startTime: Double(index * 5), endTime: Double(index * 5 + 4), text: text, speakerID: nil, isUncertain: false, isProvisional: false, isEdited: false)
        }
        let projectRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let intelligence = LocalIntelligence(modelsURL: projectRoot.appendingPathComponent("tmp/tests/unused-models"), ollama: client)
        let notes = try await intelligence.generateNotes(meeting: meeting, segments: segments, selection: selection)
        let items = notes.summary + notes.decisions + notes.actionItems
        XCTAssertFalse(items.isEmpty)
        XCTAssertFalse(notes.isPartial)
        XCTAssertEqual(notes.model, selection)
        for item in items {
            XCTAssertTrue(EvidenceValidator.isSupported(item.evidenceIDs, allowed: Set(segments.map(\.id))))
            XCTAssertNil(item.owner)
        }
    }
}
