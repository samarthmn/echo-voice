import Foundation
import CryptoKit
import XCTest
@testable import EchoCore

final class MeetingStoreTests: XCTestCase {
    private var scratchURL: URL!
    private var paths: AppPaths!
    private var store: MeetingStore!

    override func setUpWithError() throws {
        let root: URL
        if let configured = ProcessInfo.processInfo.environment["ECHO_TEST_ROOT"] {
            root = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("tmp/core-tests", isDirectory: true)
        }
        scratchURL = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratchURL, withIntermediateDirectories: true)
        paths = AppPaths(root: scratchURL.appendingPathComponent("Application Support", isDirectory: true))
        store = try MeetingStore(paths: paths)
    }

    override func tearDownWithError() throws {
        // Release GRDB's DatabaseQueue before unlinking its SQLite files. Keeping
        // the store property alive through cleanup triggers SQLite's vnode-in-use
        // diagnostic even though the test assertions have already completed.
        store = nil
        paths = nil
        if let scratchURL, FileManager.default.fileExists(atPath: scratchURL.path) {
            try FileManager.default.removeItem(at: scratchURL)
        }
        scratchURL = nil
    }

    func testSpeechModelSurvivesRestartAndOrdinaryMeetingUpdates() throws {
        var value = meeting(id: "parakeet-meeting")
        value.speechModel = .parakeet
        try store.createMeeting(value)
        value.title = "Renamed"
        try store.updateMeeting(value)
        let reopened = try MeetingStore(paths: paths)
        XCTAssertEqual(try reopened.meeting(id: value.id)?.recognitionModel, .parakeet)
        try store.createMeeting(meeting(id: "legacy-whisper"))
        XCTAssertEqual(try reopened.meeting(id: "legacy-whisper")?.recognitionModel, .whisper)
    }

    func testLegacyMeetingJSONDefaultsToWhisper() throws {
        let encoded = try JSONEncoder().encode(meeting(id: "legacy"))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "speechModel")
        let decoded = try JSONDecoder().decode(Meeting.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.recognitionModel, .whisper)
    }

    func testMeetingLifecycleAndCrashRecoveryPersistAcrossStoreInstances() throws {
        let first = meeting(id: "meeting-1", state: .recording)
        let second = meeting(id: "meeting-2", state: .ready)
        try store.createMeeting(first)
        try store.createMeeting(second)

        let reopened = try MeetingStore(paths: paths)
        let recovered = try reopened.recoverInterruptedMeetings()

        XCTAssertEqual(recovered.map(\.id), ["meeting-1"])
        XCTAssertEqual(try reopened.meeting(id: "meeting-1")?.state, .interrupted)
        XCTAssertEqual(try reopened.meeting(id: "meeting-2")?.state, .ready)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.meetingDirectory("meeting-1").path))
    }

    func testStartupRecoversVerifiedClosedPartialChunkFromSidecar() throws {
        try store.createMeeting(meeting(id: "meeting-1"))
        let data = Data("closed caf bytes".utf8)
        let partial = paths.meetingDirectory("meeting-1").appendingPathComponent("audio/mic.partial.caf")
        try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: partial)
        let recoveredChunk = chunk(
            id: "recovered", relativePath: "audio/mic.caf",
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        )
        let sidecar = paths.meetingDirectory("meeting-1").appendingPathComponent("audio/mic.caf.chunk.json")
        try JSONEncoder().encode(recoveredChunk).write(to: sidecar)
        store = nil

        store = try MeetingStore(paths: paths)

        XCTAssertEqual(try store.chunks(meetingID: "meeting-1"), [recoveredChunk])
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.meetingDirectory("meeting-1").appendingPathComponent("audio/mic.caf").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
    }

    func testStartupDoesNotImportOrDeleteChunkWhoseChecksumDoesNotMatchSidecar() throws {
        try store.createMeeting(meeting(id: "meeting-1"))
        let final = paths.meetingDirectory("meeting-1").appendingPathComponent("audio/mic.caf")
        try FileManager.default.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("actual bytes".utf8).write(to: final)
        let sidecar = final.appendingPathExtension("chunk.json")
        try JSONEncoder().encode(chunk(id: "bad", relativePath: "audio/mic.caf", sha256: String(repeating: "0", count: 64))).write(to: sidecar)
        store = nil

        XCTAssertThrowsError(try MeetingStore(paths: paths))
        XCTAssertTrue(FileManager.default.fileExists(atPath: final.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path))
    }

    func testDeferredRecoveryKeepsHealthyMeetingAvailableBesideDamagedSidecar() throws {
        try store.createMeeting(meeting(id: "healthy"))
        try store.createMeeting(meeting(id: "damaged"))
        let audio = paths.meetingDirectory("damaged").appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        let final = audio.appendingPathComponent("mic.caf")
        try Data("actual bytes".utf8).write(to: final)
        let sidecar = final.appendingPathExtension("chunk.json")
        var wrong = chunk(id: "bad", relativePath: "audio/mic.caf", sha256: String(repeating: "0", count: 64))
        wrong.meetingID = "damaged"
        try JSONEncoder().encode(wrong).write(to: sidecar)
        store = nil

        let opened = try MeetingStore(paths: paths, deferAssetRecovery: true)
        XCTAssertEqual(Set(try opened.meetings().map(\.id)), ["healthy", "damaged"])
        let issues = try opened.recoverMeetingAssets()
        XCTAssertEqual(issues.map(\.meetingID), ["damaged"])
        XCTAssertNotNil(try opened.meeting(id: "healthy"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path))
    }

    func testDamagedDeletionJournalDoesNotBlockHealthyMeeting() throws {
        try store.createMeeting(meeting(id: "healthy"))
        try store.createMeeting(meeting(id: "damaged"))
        let directory = paths.root.appendingPathComponent("Deleted Meetings/damaged-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let journal = directory.appendingPathComponent("tombstone.json")
        try Data("invalid journal".utf8).write(to: journal)
        store = nil

        let opened = try MeetingStore(paths: paths, deferAssetRecovery: true)
        XCTAssertNotNil(try opened.meeting(id: "healthy"))
        let issues = try opened.recoverMeetingAssets()
        XCTAssertEqual(issues.map(\.meetingID), ["damaged"])
        XCTAssertNoThrow(try opened.exportSnapshot(meetingID: "healthy"))
        XCTAssertThrowsError(try opened.exportSnapshot(meetingID: "damaged"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))
    }

    func testPersistentDeletionPurgeFailureRemainsIsolatedAndRetryable() throws {
        struct PurgeFailure: Error {}
        var injected: MeetingStore? = try MeetingStore(paths: paths, deletionCheckpoint: { _, _ in },
                                                       purgeCheckpoint: { _ in throw PurgeFailure() })
        try injected!.createMeeting(meeting(id: "healthy"))
        try injected!.createMeeting(meeting(id: "deleted"))
        XCTAssertThrowsError(try injected!.deleteMeeting(id: "deleted"))
        injected = nil
        let opened = try MeetingStore(paths: paths, deletionCheckpoint: { _, _ in },
                                      purgeCheckpoint: { _ in throw PurgeFailure() }, deferAssetRecovery: true)
        let issues = try opened.recoverDeletionTransactions()
        XCTAssertEqual(issues.map(\.meetingID), ["deleted"])
        XCTAssertNoThrow(try opened.exportSnapshot(meetingID: "healthy"))
        XCTAssertNil(try opened.meeting(id: "deleted"))
        let repaired = try MeetingStore(paths: paths, deferAssetRecovery: true)
        XCTAssertTrue(try repaired.recoverDeletionTransactions().isEmpty)
        XCTAssertTrue(repaired.deletionRecoveryIssues.isEmpty)
    }

    func testChunkWritesAreIdempotentAndScopedToMeeting() throws {
        try store.createMeeting(meeting(id: "a"))
        try store.createMeeting(meeting(id: "b"))
        try writeAsset(meetingID: "a", relativePath: "audio/mic.caf", contents: "a")
        try writeAsset(meetingID: "b", relativePath: "audio/mic.caf", contents: "b")
        let chunkA = chunk(id: "chunk-1", meetingID: "a", relativePath: "audio/mic.caf", sha256: "aaa")
        let chunkB = chunk(id: "chunk-1", meetingID: "b", relativePath: "audio/mic.caf", sha256: "bbb")

        try store.addChunk(chunkA)
        try store.addChunk(chunkA)
        try store.addChunk(chunkB)

        XCTAssertEqual(try store.chunks(meetingID: "a"), [chunkA])
        XCTAssertEqual(try store.chunks(meetingID: "b"), [chunkB])
        XCTAssertEqual(try store.chunks(meetingID: "a", track: .remote), [])
    }

    func testChunkRegistrationRejectsConflictingImmutableMetadataWithoutTouchingFiles() throws {
        try store.createMeeting(meeting(id: "meeting-1"))
        try writeAsset(meetingID: "meeting-1", relativePath: "audio/mic.caf", contents: "canonical audio")
        try writeAsset(meetingID: "meeting-1", relativePath: "audio/alternate.caf", contents: "alternate audio")
        let original = chunk(relativePath: "audio/mic.caf", sha256: "canonical-checksum")
        try store.addChunk(original)

        let canonicalURL = paths.meetingDirectory("meeting-1").appendingPathComponent("audio/mic.caf")
        let alternateURL = paths.meetingDirectory("meeting-1").appendingPathComponent("audio/alternate.caf")
        let protectedFiles: [(URL, Data)] = [
            (canonicalURL, Data("canonical audio".utf8)),
            (canonicalURL.appendingPathExtension("chunk.json"), Data("canonical sidecar".utf8)),
            (canonicalURL.appendingPathExtension("intent.json"), Data("canonical intent".utf8)),
            (alternateURL, Data("alternate audio".utf8)),
            (alternateURL.appendingPathExtension("chunk.json"), Data("alternate sidecar".utf8)),
            (alternateURL.appendingPathExtension("intent.json"), Data("alternate intent".utf8)),
        ]
        for (url, contents) in protectedFiles where !FileManager.default.fileExists(atPath: url.path) {
            try contents.write(to: url)
        }

        var changedChecksum = original
        changedChecksum.sha256 = "different-checksum"
        var changedTiming = original
        changedTiming.startTime = 0.25
        var changedTrack = original
        changedTrack.track = .remote
        var changedPath = original
        changedPath.relativePath = "audio/alternate.caf"

        for conflicting in [changedChecksum, changedTiming, changedTrack, changedPath] {
            XCTAssertThrowsError(try store.addChunk(conflicting)) { error in
                XCTAssertEqual(error as? EchoCoreError, .invalidValue("chunk registration conflict"))
            }
            XCTAssertEqual(try store.chunks(meetingID: "meeting-1"), [original])
            for (url, contents) in protectedFiles {
                XCTAssertEqual(try Data(contentsOf: url), contents, "Conflict touched \(url.lastPathComponent)")
            }
        }
    }

    func testChunkRejectsTraversalMissingFilesAndSymlinks() throws {
        try store.createMeeting(meeting(id: "meeting-1"))
        let outside = scratchURL.appendingPathComponent("outside.caf")
        try Data("outside".utf8).write(to: outside)
        let meetingDirectory = paths.meetingDirectory("meeting-1")
        try FileManager.default.createDirectory(at: meetingDirectory.appendingPathComponent("audio"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: meetingDirectory.appendingPathComponent("audio/link.caf"),
            withDestinationURL: outside
        )

        XCTAssertThrowsError(try store.addChunk(chunk(meetingID: "meeting-1", relativePath: "../outside.caf")))
        XCTAssertThrowsError(try store.addChunk(chunk(meetingID: "meeting-1", relativePath: "audio/missing.caf")))
        XCTAssertThrowsError(try store.addChunk(chunk(meetingID: "meeting-1", relativePath: "audio/link.caf")))
    }

    func testPathsUseServiceDirectoryNamesAndRejectUnsafeMeetingIDs() throws {
        XCTAssertEqual(paths.meetingsURL.lastPathComponent, "meetings")
        XCTAssertEqual(paths.runtimeURL.lastPathComponent, "runtime")
        XCTAssertEqual(paths.modelsURL.lastPathComponent, "models")
        XCTAssertThrowsError(try paths.resolveMeetingAsset(meetingID: "../escape", relativePath: "audio.caf"))
        XCTAssertThrowsError(try paths.resolveMeetingAsset(meetingID: "meeting with spaces", relativePath: "audio.caf"))
        XCTAssertThrowsError(try paths.resolveMeetingAsset(meetingID: String(repeating: "a", count: 129), relativePath: "audio.caf"))
    }

    func testAssetResolutionRejectsSymlinkedMeetingDirectoryOutsideRoot() throws {
        let outside = scratchURL.appendingPathComponent("outside-meeting", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outside.appendingPathComponent("audio.caf"))
        let meetingLink = paths.meetingDirectory("linked")
        try FileManager.default.createSymbolicLink(at: meetingLink, withDestinationURL: outside)

        XCTAssertThrowsError(try paths.resolveMeetingAsset(meetingID: "linked", relativePath: "audio.caf"))
    }

    func testStoreRejectsSymlinkedManagedDirectoryOutsideRoot() throws {
        let alternateRoot = scratchURL.appendingPathComponent("Unsafe Root", isDirectory: true)
        let outside = scratchURL.appendingPathComponent("external-meetings", isDirectory: true)
        try FileManager.default.createDirectory(at: alternateRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: alternateRoot.appendingPathComponent("meetings", isDirectory: true),
            withDestinationURL: outside
        )

        XCTAssertThrowsError(try MeetingStore(paths: AppPaths(root: alternateRoot)))
    }

    func testSegmentRetryUpdatesMachineFieldsButPreservesHumanText() throws {
        try store.createMeeting(meeting(id: "meeting-1"))
        let original = segment(text: "machine transcript")
        try store.upsertSegments([original])
        try store.editSegment(id: original.id, text: "human correction")

        var retry = original
        retry.text = "different machine transcript"
        retry.endTime = 8
        retry.isProvisional = false
        try store.upsertSegments([retry])

        let saved = try XCTUnwrap(store.segments(meetingID: "meeting-1").first)
        XCTAssertEqual(saved.text, "human correction")
        XCTAssertEqual(saved.endTime, 8)
        XCTAssertTrue(saved.isEdited)
        XCTAssertFalse(saved.isProvisional)
        XCTAssertEqual(try store.meeting(id: "meeting-1")?.transcriptRevision, 1)
    }

    func testSegmentIDsAreMeetingScopedAndAmbiguousEditIsRejected() throws {
        try store.createMeeting(meeting(id: "meeting-1"))
        try store.createMeeting(meeting(id: "meeting-2"))
        try store.upsertSegments([
            segment(id: "shared", meetingID: "meeting-1", text: "one"),
            segment(id: "shared", meetingID: "meeting-2", text: "two"),
        ])

        XCTAssertEqual(try store.segments(meetingID: "meeting-1").map(\.text), ["one"])
        XCTAssertEqual(try store.segments(meetingID: "meeting-2").map(\.text), ["two"])
        XCTAssertThrowsError(try store.editSegment(id: "shared", text: "ambiguous"))
    }

    func testEditingTranscriptMakesExistingNotesOlderThanCurrentRevision() throws {
        try store.createMeeting(meeting(id: "meeting-1"))
        let transcript = segment()
        try store.upsertSegments([transcript])
        let note = MeetingNotes(
            id: "notes-1",
            meetingID: "meeting-1",
            createdAt: Date(timeIntervalSince1970: 50),
            transcriptRevision: 0,
            summary: [NoteItem(id: "summary-1", text: "Summary", evidenceIDs: [transcript.id])],
            decisions: [],
            actionItems: [],
            isEdited: false,
            isPartial: false
        )
        try store.saveNotes(note)

        try store.editSegment(id: transcript.id, text: "corrected")

        let revision = try XCTUnwrap(store.meeting(id: "meeting-1")?.transcriptRevision)
        XCTAssertEqual(revision, 1)
        XCTAssertLessThan(try XCTUnwrap(store.notes(meetingID: "meeting-1").first).transcriptRevision, revision)
    }

    func testCachedMeetingMetadataUpdateCannotDecreaseTranscriptRevision() throws {
        try store.createMeeting(meeting(id: "meeting-1"))
        var cachedMeeting = try XCTUnwrap(store.meeting(id: "meeting-1"))
        let transcript = segment()
        try store.upsertSegments([transcript])
        try store.editSegment(id: transcript.id, text: "corrected")

        cachedMeeting.title = "Renamed from cached value"
        cachedMeeting.state = .finalizing
        try store.updateMeeting(cachedMeeting)

        let saved = try XCTUnwrap(store.meeting(id: "meeting-1"))
        XCTAssertEqual(saved.title, "Renamed from cached value")
        XCTAssertEqual(saved.state, .finalizing)
        XCTAssertEqual(saved.transcriptRevision, 1)
    }

    func testReplacingWindowRemovesOnlyStaleProvisionalSegmentsAndRefreshesSearch() throws {
        try store.createMeeting(meeting(id: "meeting-1"))
        var edited = segment(id: "edited", text: "machine wording")
        var final = segment(id: "final", startTime: 5, text: "final wording")
        final.isProvisional = false
        let stale = segment(id: "stale", startTime: 9, text: "obsolete keyword")
        try store.upsertSegments([edited, final, stale])
        try store.editSegment(id: edited.id, text: "human wording")
        let revisionBeforeReplacement = try XCTUnwrap(store.meeting(id: "meeting-1")?.transcriptRevision)

        edited.text = "retry machine wording"
        edited.endTime = 4
        var replacement = segment(id: "replacement", startTime: 10, text: "current keyword")
        replacement.isProvisional = false
        try store.replaceSegments(
            meetingID: "meeting-1",
            windowID: "window-1",
            segments: [edited, replacement]
        )

        let saved = try store.segments(meetingID: "meeting-1")
        XCTAssertEqual(Set(saved.map(\.id)), ["edited", "final", "replacement"])
        XCTAssertEqual(saved.first(where: { $0.id == "edited" })?.text, "human wording")
        XCTAssertEqual(saved.first(where: { $0.id == "edited" })?.endTime, 4)
        XCTAssertEqual(try store.search("obsolete"), [])
        XCTAssertEqual(try store.search("current").map(\.segment.id), ["replacement"])
        XCTAssertEqual(try store.meeting(id: "meeting-1")?.transcriptRevision, revisionBeforeReplacement + 1)
    }

    func testFinalWindowKeepsOmittedHumanEditAndMarksItFinal() throws {
        try store.createMeeting(meeting(id: "meeting-1"))
        let edited = segment(id: "edited", text: "machine")
        try store.upsertSegments([edited])
        try store.editSegment(id: edited.id, text: "human correction")

        try store.replaceSegments(meetingID: "meeting-1", windowID: "window-1", segments: [], isFinal: true)

        let saved = try XCTUnwrap(store.segments(meetingID: "meeting-1").first)
        XCTAssertEqual(saved.id, "edited")
        XCTAssertEqual(saved.text, "human correction")
        XCTAssertTrue(saved.isEdited)
        XCTAssertFalse(saved.isProvisional)
    }

    func testNewFinalWindowMakesPreviouslySavedPartialNotesStale() throws {
        try store.createMeeting(meeting(id: "meeting-1"))
        try store.saveNotes(MeetingNotes(
            id: "partial-notes", meetingID: "meeting-1", createdAt: Date(timeIntervalSince1970: 20),
            transcriptRevision: 0,
            summary: [NoteItem(id: "summary", text: "Partial summary", evidenceIDs: [])],
            decisions: [], actionItems: [], isEdited: false, isPartial: true
        ))
        var finalEvidence = segment(id: "late-final", text: "late evidence")
        finalEvidence.isProvisional = false

        try store.replaceSegments(
            meetingID: "meeting-1", windowID: "window-1",
            segments: [finalEvidence], isFinal: true
        )

        let currentRevision = try XCTUnwrap(store.meeting(id: "meeting-1")?.transcriptRevision)
        XCTAssertEqual(currentRevision, 1)
        XCTAssertLessThan(try XCTUnwrap(store.notes(meetingID: "meeting-1").first?.transcriptRevision), currentRevision)
    }

    func testTrustedFinalReconciliationRemovesOmittedMachineFinalButKeepsHumanEdit() throws {
        try store.createMeeting(meeting(id: "meeting-1"))
        var staleMachineFinal = segment(id: "stale-final", text: "duplicated boundary text")
        staleMachineFinal.isProvisional = false
        var humanFinal = segment(id: "human-final", startTime: 5, text: "machine original")
        humanFinal.isProvisional = false
        try store.upsertSegments([staleMachineFinal, humanFinal])
        try store.editSegment(id: humanFinal.id, text: "human correction")

        try store.replaceSegments(
            meetingID: "meeting-1", windowID: "window-1", segments: [],
            isFinal: true, reconcileFinal: true
        )

        let saved = try store.segments(meetingID: "meeting-1")
        XCTAssertEqual(saved.map(\.id), ["human-final"])
        XCTAssertEqual(saved.first?.text, "human correction")
        XCTAssertTrue(try store.search("duplicated").isEmpty)
    }

    func testGeneratedNotesRetryDoesNotOverwriteHumanEditedNotes() throws {
        try store.createMeeting(meeting(id: "meeting-1"))
        let edited = MeetingNotes(
            id: "notes-1", meetingID: "meeting-1", createdAt: Date(timeIntervalSince1970: 10),
            transcriptRevision: 1,
            summary: [NoteItem(id: "n", text: "Human summary", evidenceIDs: [])],
            decisions: [], actionItems: [], isEdited: true, isPartial: false
        )
        let generatedRetry = MeetingNotes(
            id: "notes-1", meetingID: "meeting-1", createdAt: Date(timeIntervalSince1970: 20),
            transcriptRevision: 2,
            summary: [NoteItem(id: "n", text: "Machine summary", evidenceIDs: [])],
            decisions: [], actionItems: [], isEdited: false, isPartial: false
        )

        try store.saveNotes(edited)
        try store.saveNotes(generatedRetry)

        let saved = try XCTUnwrap(store.notes(meetingID: "meeting-1").first)
        XCTAssertEqual(saved.summary.first?.text, "Human summary")
        XCTAssertTrue(saved.isEdited)
        XCTAssertEqual(saved.transcriptRevision, 1)
    }

    func testSearchHandlesFTSSyntaxAsLiteralTextAndReturnsMatchingMeeting() throws {
        try store.createMeeting(meeting(id: "meeting-1", title: "Planning"))
        try store.upsertSegments([
            segment(id: "one", text: "C++ release (alpha) owner@example.com"),
            segment(id: "two", text: "ordinary unrelated sentence"),
        ])

        XCTAssertEqual(try store.search("C++ (alpha)").map(\.segment.id), ["one"])
        XCTAssertEqual(try store.search("owner@example.com").first?.meetingTitle, "Planning")
        XCTAssertEqual(try store.search("  "), [])
        XCTAssertNoThrow(try store.search("\" OR * NOT (") )
    }

    func testJobEnqueueIsIdempotentAndRunningJobsRecoverToPending() throws {
        try store.createMeeting(meeting(id: "meeting-1"))
        let created = Date(timeIntervalSince1970: 10)
        let pending = ProcessingJob(
            id: "job-1", meetingID: "meeting-1", kind: .transcribe, status: .pending,
            payload: "{\"window\":1}", attempts: 0, error: nil, createdAt: created
        )
        try store.enqueue(pending)
        var running = pending
        running.status = .running
        running.attempts = 1
        try store.updateJob(running)
        try store.enqueue(pending)

        XCTAssertEqual(try store.jobs(meetingID: "meeting-1").first?.status, .running)
        try store.recoverRunningJobs()
        let recovered = try XCTUnwrap(store.jobs(meetingID: "meeting-1").first)
        XCTAssertEqual(recovered.status, .pending)
        XCTAssertEqual(recovered.attempts, 1)
        XCTAssertNotNil(recovered.error)
    }

    func testExporterCreatesIndependentAtomicExportsWithRawAndDerivedAssets() throws {
        try store.createMeeting(meeting(id: "meeting-1", title: "Weekly / Sync"))
        try writeAsset(meetingID: "meeting-1", relativePath: "audio/mic.caf", contents: "raw microphone")
        try writeAsset(meetingID: "meeting-1", relativePath: "audio/clean.caf", contents: "clean microphone")
        try store.addChunk(chunk(id: "raw", track: .microphone, relativePath: "audio/mic.caf", sha256: "raw"))
        try store.addChunk(chunk(id: "clean", track: .cleanMicrophone, relativePath: "audio/clean.caf", sha256: "clean"))
        try store.upsertSegments([segment(text: "Hello export")])
        let destination = scratchURL.appendingPathComponent("Exports", isDirectory: true)
        let exporter = MeetingExporter(store: store)

        let first = try exporter.export(meetingID: "meeting-1", to: destination)
        let second = try exporter.export(meetingID: "meeting-1", to: destination)

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try String(contentsOf: first.appendingPathComponent("transcript.txt"), encoding: .utf8), "Hello export\n")
        XCTAssertEqual(try String(contentsOf: first.appendingPathComponent("audio/microphone/mic.caf"), encoding: .utf8), "raw microphone")
        XCTAssertEqual(try String(contentsOf: first.appendingPathComponent("audio/cleanMicrophone/clean.caf"), encoding: .utf8), "clean microphone")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.appendingPathComponent("meeting.json").path))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(ExportSnapshot.self, from: Data(contentsOf: first.appendingPathComponent("meeting.json")))
        XCTAssertEqual(Set(manifest.chunks.map(\.relativePath)), ["audio/microphone/mic.caf", "audio/cleanMicrophone/clean.caf"])
        for exportedChunk in manifest.chunks {
            XCTAssertTrue(FileManager.default.fileExists(atPath: first.appendingPathComponent(exportedChunk.relativePath).path))
        }
        XCTAssertFalse((try FileManager.default.contentsOfDirectory(atPath: destination.path)).contains { $0.hasPrefix(".echo-export-") })
    }

    func testExportedMarkdownEvidenceResolvesAfterMeetingDeletion() throws {
        try store.createMeeting(meeting(id: "meeting-1"))
        let transcript = segment(id: "spoken-evidence", startTime: 12, text: "We agreed to ship the update.")
        try store.upsertSegments([transcript])
        try writeAsset(meetingID: "meeting-1", relativePath: "screenshots/chart (final).png", contents: "fixture")
        try store.addScreenshot(ScreenshotRecord(id: "visual-evidence", meetingID: "meeting-1", relativePath: "screenshots/chart (final).png", capturedAt: 14, perceptualHash: "fixture", interpretation: "A chart"))
        try store.saveNotes(MeetingNotes(id: "notes", meetingID: "meeting-1", createdAt: Date(), transcriptRevision: 0,
            summary: [NoteItem(id: "item", text: "The update was approved.", evidenceIDs: [transcript.id, "visual-evidence"])],
            decisions: [], actionItems: [], isEdited: false, isPartial: false))
        let exported = try MeetingExporter(store: store).export(meetingID: "meeting-1", to: scratchURL.appendingPathComponent("Exports"))
        try store.deleteMeeting(id: "meeting-1")

        let notes = try String(contentsOf: exported.appendingPathComponent("notes.md"), encoding: .utf8)
        let text = try String(contentsOf: exported.appendingPathComponent("transcript.md"), encoding: .utf8)
        let linkPrefix = "(transcript.md#"
        let start = try XCTUnwrap(notes.range(of: linkPrefix)).upperBound
        let end = try XCTUnwrap(notes[start...].firstIndex(of: ")"))
        let anchor = String(notes[start..<end])
        XCTAssertTrue(text.contains("<a id=\"\(anchor)\"></a>"))
        XCTAssertTrue(notes.contains("[00:00:12]"))
        XCTAssertTrue(notes.contains("[Screenshot 00:00:14](screenshots/chart%20%28final%29.png)"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: exported.appendingPathComponent("screenshots/chart (final).png").path))
    }

    func testExportSnapshotKeepsNotesAndEvidenceConsistentDuringConcurrentWrite() throws {
        store = nil
        let snapshotReachedEvidence = DispatchSemaphore(value: 0)
        let writerStarted = DispatchSemaphore(value: 0)
        store = try MeetingStore(
            paths: paths,
            deletionCheckpoint: { _, _ in },
            purgeCheckpoint: { _ in },
            exportSnapshotCheckpoint: {
                snapshotReachedEvidence.signal()
                _ = writerStarted.wait(timeout: .now() + 5)
            }
        )
        try store.createMeeting(meeting(id: "meeting-1"))
        let original = segment(id: "original-evidence", startTime: 1, text: "Original evidence")
        try store.upsertSegments([original])
        try store.saveNotes(MeetingNotes(
            id: "original-notes", meetingID: "meeting-1", createdAt: Date(timeIntervalSince1970: 10), transcriptRevision: 0,
            summary: [NoteItem(id: "original-item", text: "Original summary", evidenceIDs: [original.id])],
            decisions: [], actionItems: [], isEdited: false, isPartial: false
        ))

        let queue = DispatchQueue(label: "EchoCoreTests.export-snapshot", attributes: .concurrent)
        let group = DispatchGroup()
        let result = ConcurrentExportResult()
        let exportStore = try XCTUnwrap(store)
        let destination = scratchURL.appendingPathComponent("Concurrent Export", isDirectory: true)
        let replacement = segment(id: "replacement-evidence", startTime: 2, text: "Replacement evidence")
        let replacementNotes = MeetingNotes(
            id: "replacement-notes", meetingID: "meeting-1", createdAt: Date(timeIntervalSince1970: 20), transcriptRevision: 0,
            summary: [NoteItem(id: "replacement-item", text: "Replacement summary", evidenceIDs: [replacement.id])],
            decisions: [], actionItems: [], isEdited: false, isPartial: false
        )
        group.enter()
        queue.async {
            defer { group.leave() }
            do {
                result.record(url: try MeetingExporter(store: exportStore).export(meetingID: "meeting-1", to: destination))
            } catch { result.record(error: error) }
        }
        XCTAssertEqual(snapshotReachedEvidence.wait(timeout: .now() + 5), .success)

        group.enter()
        queue.async {
            defer { group.leave() }
            writerStarted.signal()
            do {
                try exportStore.upsertSegments([replacement])
                try exportStore.saveNotes(replacementNotes)
            } catch { result.record(error: error) }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        let captured = result.value()
        XCTAssertTrue(captured.errors.isEmpty)

        let exported = try XCTUnwrap(captured.url)
        let notes = try String(contentsOf: exported.appendingPathComponent("notes.md"), encoding: .utf8)
        let transcript = try String(contentsOf: exported.appendingPathComponent("transcript.md"), encoding: .utf8)
        let linkPrefix = "(transcript.md#"
        let start = try XCTUnwrap(notes.range(of: linkPrefix)).upperBound
        let end = try XCTUnwrap(notes[start...].firstIndex(of: ")"))
        let anchor = String(notes[start..<end])
        XCTAssertTrue(transcript.contains("<a id=\"\(anchor)\"></a>"))
        XCTAssertTrue(notes.contains("Original summary"))
        XCTAssertFalse(notes.contains("Replacement summary"))
    }

    func testStartupCompletesDeletionInterruptedBeforeAssetMove() throws {
        try store.createMeeting(meeting(id: "meeting-1"))
        try writeAsset(meetingID: "meeting-1", relativePath: "audio/mic.caf", contents: "audio")
        try store.addChunk(chunk(relativePath: "audio/mic.caf"))
        let tombstone = try stageDeletionTombstone(meetingID: "meeting-1")
        store = nil

        store = try MeetingStore(paths: paths)

        XCTAssertNil(try store.meeting(id: "meeting-1"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.meetingDirectory("meeting-1").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tombstone.path))
    }

    func testStartupCompletesDeletionInterruptedAfterAssetMove() throws {
        try store.createMeeting(meeting(id: "meeting-1"))
        try writeAsset(meetingID: "meeting-1", relativePath: "audio/mic.caf", contents: "audio")
        try store.addChunk(chunk(relativePath: "audio/mic.caf"))
        let tombstone = try stageDeletionTombstone(meetingID: "meeting-1")
        try FileManager.default.moveItem(
            at: paths.meetingDirectory("meeting-1"),
            to: tombstone.appendingPathComponent("assets", isDirectory: true)
        )
        store = nil

        store = try MeetingStore(paths: paths)

        XCTAssertNil(try store.meeting(id: "meeting-1"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tombstone.path))
    }

    func testInterruptedPostCommitPurgeIsSurfacedAndRetriedAtStartup() throws {
        struct InjectedPurgeFailure: Error {}
        let destination = scratchURL.appendingPathComponent("Exports", isDirectory: true)
        var injectedStore: MeetingStore? = try MeetingStore(
            paths: paths,
            deletionCheckpoint: { _, _ in },
            purgeCheckpoint: { _ in throw InjectedPurgeFailure() }
        )
        try injectedStore?.createMeeting(meeting(id: "meeting-1", title: "Purge me"))
        try writeAsset(meetingID: "meeting-1", relativePath: "audio/mic.caf", contents: "audio to purge")
        try injectedStore?.addChunk(chunk(relativePath: "audio/mic.caf"))
        let exported = try MeetingExporter(store: try XCTUnwrap(injectedStore)).export(meetingID: "meeting-1", to: destination)

        XCTAssertThrowsError(try injectedStore?.deleteMeeting(id: "meeting-1"))
        XCTAssertNil(try injectedStore?.meeting(id: "meeting-1"))
        let deletedRoot = paths.root.appendingPathComponent("Deleted Meetings", isDirectory: true)
        let retained = try FileManager.default.contentsOfDirectory(at: deletedRoot, includingPropertiesForKeys: nil)
        XCTAssertEqual(retained.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained[0].appendingPathComponent("assets/audio/mic.caf").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: exported.path))
        injectedStore = nil

        store = try MeetingStore(paths: paths)

        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: deletedRoot.path)).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: exported.path))
    }

    func testFailedDeletionRollbackNeverDeletesBackupAssets() throws {
        let injectedStore = try MeetingStore(paths: paths) { liveURL, _ in
            try FileManager.default.createDirectory(at: liveURL, withIntermediateDirectories: true)
            struct InjectedFailure: Error {}
            throw InjectedFailure()
        }
        try injectedStore.createMeeting(meeting(id: "meeting-1"))
        try writeAsset(meetingID: "meeting-1", relativePath: "audio/mic.caf", contents: "only audio copy")
        try injectedStore.addChunk(chunk(relativePath: "audio/mic.caf"))

        XCTAssertThrowsError(try injectedStore.deleteMeeting(id: "meeting-1"))

        XCTAssertNotNil(try injectedStore.meeting(id: "meeting-1"))
        let deletedRoot = paths.root.appendingPathComponent("Deleted Meetings", isDirectory: true)
        let tombstones = try FileManager.default.contentsOfDirectory(at: deletedRoot, includingPropertiesForKeys: nil)
        let backup = try XCTUnwrap(tombstones.first(where: {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("assets/audio/mic.caf").path)
        }))
        XCTAssertEqual(try String(contentsOf: backup.appendingPathComponent("assets/audio/mic.caf"), encoding: .utf8), "only audio copy")
    }

    func testDeletePurgesMeetingDataAndLeavesIndependentExportsAlone() throws {
        try store.createMeeting(meeting(id: "meeting-1", title: "Delete me"))
        try writeAsset(meetingID: "meeting-1", relativePath: "audio/mic.caf", contents: "audio")
        try store.addChunk(chunk(relativePath: "audio/mic.caf"))
        try store.enqueue(ProcessingJob(
            id: "delete-job", meetingID: "meeting-1", kind: .transcribe, status: .pending,
            payload: "{}", attempts: 0, error: nil, createdAt: Date(timeIntervalSince1970: 10)
        ))
        let destination = scratchURL.appendingPathComponent("Exports", isDirectory: true)
        let exported = try MeetingExporter(store: store).export(meetingID: "meeting-1", to: destination)

        try store.deleteMeeting(id: "meeting-1")

        XCTAssertNil(try store.meeting(id: "meeting-1"))
        XCTAssertTrue(try store.jobs(meetingID: "meeting-1").isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.meetingDirectory("meeting-1").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: exported.path))
        let deletedRoot = paths.root.appendingPathComponent("Deleted Meetings", isDirectory: true)
        let tombstones = try FileManager.default.contentsOfDirectory(at: deletedRoot, includingPropertiesForKeys: nil)
        XCTAssertTrue(tombstones.isEmpty)
    }

    func testConcurrentWritesRemainComplete() throws {
        try store.createMeeting(meeting(id: "meeting-1"))
        let queue = DispatchQueue(label: "EchoCoreTests.concurrent", attributes: .concurrent)
        let group = DispatchGroup()
        let failures = NSLock()
        var thrownErrors: [Error] = []
        for index in 0..<40 {
            group.enter()
            queue.async {
                defer { group.leave() }
                do {
                    try self.store.upsertSegments([self.segment(id: "segment-\(index)", startTime: Double(index), text: "word \(index)")])
                } catch {
                    failures.lock()
                    thrownErrors.append(error)
                    failures.unlock()
                }
            }
        }
        group.wait()

        XCTAssertTrue(thrownErrors.isEmpty)
        XCTAssertEqual(try store.segments(meetingID: "meeting-1").count, 40)
    }

    private func meeting(id: String, title: String = "Test Meeting", state: MeetingState = .ready) -> Meeting {
        Meeting(
            id: id, title: title, startedAt: Date(timeIntervalSince1970: 1), endedAt: nil,
            state: state, language: "en", sourceName: "Test Source",
            usesEchoCancellation: true, transcriptRevision: 0
        )
    }

    private func chunk(
        id: String = "chunk-1",
        meetingID: String = "meeting-1",
        track: AudioTrack = .microphone,
        relativePath: String = "audio/mic.caf",
        sha256: String = "abc"
    ) -> CapturedChunk {
        CapturedChunk(
            id: id, meetingID: meetingID, epochID: "epoch-1", track: track,
            relativePath: relativePath, startTime: 0, duration: 5,
            sampleRate: 48_000, frameCount: 240_000, sha256: sha256
        )
    }

    private func segment(
        id: String = "segment-1",
        meetingID: String = "meeting-1",
        startTime: Double = 1,
        text: String = "Hello world"
    ) -> TranscriptSegment {
        TranscriptSegment(
            id: id, meetingID: meetingID, windowID: "window-1", track: .cleanMicrophone,
            startTime: startTime, endTime: startTime + 2, text: text, speakerID: nil,
            isUncertain: false, isProvisional: true, isEdited: false
        )
    }

    private func writeAsset(meetingID: String, relativePath: String, contents: String) throws {
        let destination = paths.meetingDirectory(meetingID).appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: destination)
    }

    private func stageDeletionTombstone(meetingID: String) throws -> URL {
        struct Tombstone: Codable {
            let meeting: Meeting
            let deletedAt: Date
            let chunks: [CapturedChunk]
            let screenshots: [ScreenshotRecord]
        }
        let directory = paths.root
            .appendingPathComponent("Deleted Meetings", isDirectory: true)
            .appendingPathComponent("\(meetingID)-interrupted", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let value = Tombstone(
            meeting: try XCTUnwrap(store.meeting(id: meetingID)),
            deletedAt: Date(timeIntervalSince1970: 100),
            chunks: try store.chunks(meetingID: meetingID),
            screenshots: try store.screenshots(meetingID: meetingID)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: directory.appendingPathComponent("tombstone.json"), options: .atomic)
        return directory
    }
}

private final class ConcurrentExportResult: @unchecked Sendable {
    private let lock = NSLock()
    private var url: URL?
    private var errors: [Error] = []

    func record(url: URL) {
        lock.lock(); defer { lock.unlock() }
        self.url = url
    }

    func record(error: Error) {
        lock.lock(); defer { lock.unlock() }
        errors.append(error)
    }

    func value() -> (url: URL?, errors: [Error]) {
        lock.lock(); defer { lock.unlock() }
        return (url, errors)
    }
}
