import Foundation
import AVFoundation
import XCTest
import EchoCore
import EchoIntelligence
@testable import EchoRuntime

final class RedactionCoordinatorTests: XCTestCase {
    func testDeletionScrubsLegacyRecognitionTextOutsideReconciledPassageBounds() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ECHO_TEST_ROOT"] ?? FileManager.default.currentDirectoryPath + "/tmp/tests")
            .appendingPathComponent("redaction-provenance-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(paths: AppPaths(root: root))
        try store.createMeeting(Meeting(id: "meeting", title: "Provenance", startedAt: Date(), endedAt: Date(),
                                        state: .ready, language: "en", sourceName: "Test",
                                        usesEchoCancellation: false, transcriptRevision: 0))
        let left = TranscriptSegment(id: "left", meetingID: "meeting", windowID: "left", track: .remote,
                                     startTime: 26, endTime: 29, text: "We should ship the release", speakerID: nil,
                                     isUncertain: false, isProvisional: false, isEdited: false)
        let right = TranscriptSegment(id: "right", meetingID: "meeting", windowID: "right", track: .remote,
                                      startTime: 29.25, endTime: 30, text: "tomorrow.", speakerID: nil,
                                      isUncertain: true, isProvisional: false, isEdited: false,
                                      recognitionEvidence: RecognitionEvidence(originalText: "Ship the release tomorrow."))
        let bounded = TranscriptSegment(id: "bounded", meetingID: "meeting", windowID: "right", track: .remote,
                                        startTime: 30, endTime: 31, text: "next.", speakerID: nil,
                                        isUncertain: true, isProvisional: false, isEdited: false,
                                        recognitionEvidence: RecognitionEvidence(originalText: "Ship the release next.", sourceStart: 28, sourceEnd: 31))
        let unrelated = TranscriptSegment(id: "unrelated", meetingID: "meeting", windowID: "right", track: .remote,
                                          startTime: 40, endTime: 41, text: "Unrelated.", speakerID: nil,
                                          isUncertain: false, isProvisional: false, isEdited: false,
                                          recognitionEvidence: RecognitionEvidence(originalText: "Unrelated.", sourceStart: 40, sourceEnd: 41))
        try store.replaceSegments(meetingID: "meeting", windowID: "left", segments: [left], isFinal: true)
        try store.replaceSegments(meetingID: "meeting", windowID: "right", segments: [right, bounded, unrelated], isFinal: true)
        let version = TranscriptVersion(id: "history", meetingID: "meeting", configuration: nil, audioFingerprint: "fixture")
        try store.saveTranscriptVersion(version)
        try store.saveVersionWindow(versionID: version.id, windowID: "right", segments: [right, bounded, unrelated])
        let coordinator = RedactionCoordinator(store: store, paths: store.paths)
        try await coordinator.commit(preview: coordinator.preview(meetingID: "meeting", segmentID: "left"))
        let retained = try store.segments(meetingID: "meeting")
        XCTAssertEqual(retained.map(\.text), ["tomorrow.", "next.", "Unrelated."])
        XCTAssertNil(retained.first?.recognitionEvidence)
        XCTAssertNil(retained.first(where: { $0.id == "bounded" })?.recognitionEvidence)
        XCTAssertEqual(retained.first(where: { $0.id == "unrelated" })?.recognitionEvidence?.originalText, "Unrelated.")
        XCTAssertNil(try store.versionSegments(versionID: version.id).first?.recognitionEvidence)
        let exported = try MeetingExporter(store: store).export(meetingID: "meeting", to: root.appendingPathComponent("exports"))
        XCTAssertFalse(try String(contentsOf: exported.appendingPathComponent("meeting.json"), encoding: .utf8).contains("Ship the release"))
    }

    func testChangedTextRequiresANewDeletionPreview() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ECHO_TEST_ROOT"] ?? FileManager.default.currentDirectoryPath + "/tmp/tests")
            .appendingPathComponent("redaction-stale-preview-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(paths: AppPaths(root: root))
        try store.createMeeting(Meeting(id: "meeting", title: "Preview", startedAt: Date(), endedAt: Date(),
                                        state: .ready, language: "en", sourceName: "Test",
                                        usesEchoCancellation: false, transcriptRevision: 0))
        let target = TranscriptSegment(id: "target", meetingID: "meeting", windowID: "window", track: .remote,
                                       startTime: 1, endTime: 2, text: "Initial text", speakerID: nil,
                                       isUncertain: false, isProvisional: false, isEdited: false)
        try store.replaceSegments(meetingID: "meeting", windowID: "window", segments: [target], isFinal: true)
        let coordinator = RedactionCoordinator(store: store, paths: store.paths)
        let preview = try await coordinator.preview(meetingID: "meeting", segmentID: target.id)
        try store.editSegment(id: target.id, text: "Updated text")
        do {
            try await coordinator.commit(preview: preview)
            XCTFail("A changed deletion preview must not be committed")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("review deletion again"))
        }
        XCTAssertEqual(try store.segments(meetingID: "meeting").map(\.text), ["Updated text"])
        XCTAssertTrue(try store.pendingRedactions().isEmpty)
    }

    func testReadySpeakerphoneRedactionRetryDoesNotReprepareRetainedCleanAudio() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ECHO_TEST_ROOT"] ?? FileManager.default.currentDirectoryPath + "/tmp/tests")
            .appendingPathComponent("redaction-aec-retry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        let store = try MeetingStore(paths: paths)
        try store.createMeeting(Meeting(id: "meeting", title: "AEC retry", startedAt: Date(), endedAt: Date(),
                                        state: .ready, language: "en", sourceName: "Test",
                                        usesEchoCancellation: true, transcriptRevision: 0))
        for track in [AudioTrack.microphone, .remote, .cleanMicrophone] {
            let relative = (track == .cleanMicrophone ? "derived/" : "audio/") + track.rawValue + ".caf"
            let url = try paths.resolveMeetingAsset(meetingID: "meeting", relativePath: relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0, count: 1024).write(to: url)
            try store.addChunk(.init(id: track.rawValue, meetingID: "meeting", epochID: "epoch", track: track,
                                     relativePath: relative, startTime: 0, duration: 1,
                                     sampleRate: 16_000, frameCount: 16_000,
                                     sha256: try AudioWindowAssembler.digest(url)))
        }
        let target = TranscriptSegment(id: "target", meetingID: "meeting", windowID: "later", track: .remote,
                                       startTime: 2, endTime: 3, text: "delete", speakerID: nil,
                                       isUncertain: false, isProvisional: false, isEdited: false)
        try store.replaceSegments(meetingID: "meeting", windowID: "later", segments: [target], isFinal: true)
        let coordinator = RedactionCoordinator(store: store, paths: paths)
        let preview = try await coordinator.preview(meetingID: "meeting", segmentID: target.id)
        try await coordinator.commit(preview: preview)
        let processor = MeetingProcessor(store: store, paths: paths, service: LocalService(paths: paths),
                                         intelligence: LocalIntelligence(modelsURL: paths.modelsURL))
        try? await processor.finalize(meetingID: "meeting", diarizationWindowSeconds: nil, onUpdate: { _ in })
        XCTAssertFalse(try store.jobs(meetingID: "meeting").contains { $0.kind == .prepareAudio },
                       "Retained verified clean audio must not be reprocessed without its retired proof")
    }

    func testUnfinishedCaptureBlocksDeletionUntilItsBytesAreReconciled() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ECHO_TEST_ROOT"] ?? FileManager.default.currentDirectoryPath + "/tmp/tests")
            .appendingPathComponent("redaction-unfinished-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        let store = try MeetingStore(paths: paths)
        try store.createMeeting(Meeting(id: "meeting", title: "Unfinished", startedAt: Date(), endedAt: Date(),
                                        state: .ready, language: "en", sourceName: "Test",
                                        usesEchoCancellation: false, transcriptRevision: 0))
        let target = TranscriptSegment(id: "target", meetingID: "meeting", windowID: "window", track: .remote,
                                       startTime: 1, endTime: 2, text: "delete", speakerID: nil,
                                       isUncertain: false, isProvisional: false, isEdited: false)
        try store.replaceSegments(meetingID: "meeting", windowID: "window", segments: [target], isFinal: true)
        let partial = paths.meetingDirectory("meeting").appendingPathComponent("audio/microphone-partial.partial.caf")
        try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("possibly overlapping microphone bytes".utf8).write(to: partial)
        let coordinator = RedactionCoordinator(store: store, paths: paths)
        do {
            _ = try await coordinator.preview(meetingID: "meeting", segmentID: target.id)
            XCTFail("Deletion must not claim to cover unregistered capture bytes")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("unfinished"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
    }

    func testRedactionKeepsUnaffectedCompactedCleanAudio() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ECHO_TEST_ROOT"] ?? FileManager.default.currentDirectoryPath + "/tmp/tests")
            .appendingPathComponent("redaction-compacted-clean-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        let store = try MeetingStore(paths: paths)
        try store.createMeeting(Meeting(id: "meeting", title: "Compacted", startedAt: Date(), endedAt: Date(),
                                        state: .ready, language: "en", sourceName: "Test",
                                        usesEchoCancellation: true, transcriptRevision: 0))
        let directory = paths.meetingDirectory("meeting").appendingPathComponent("derived")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        buffer.frameLength = 48_000
        memset(buffer.floatChannelData![0], 0, 48_000 * MemoryLayout<Float>.size)
        let url = directory.appendingPathComponent("retained.caf")
        do {
            let writer = try AVAudioFile(forWriting: url, settings: format.settings,
                                         commonFormat: .pcmFormatFloat32, interleaved: false)
            try writer.write(from: buffer)
        }
        let chunk = CapturedChunk(id: "retained", meetingID: "meeting", epochID: "epoch",
                                  track: .cleanMicrophone, relativePath: "derived/retained.caf",
                                  startTime: 0, duration: 1, sampleRate: 48_000,
                                  frameCount: 48_000, sha256: try AudioWindowAssembler.digest(url))
        try store.addChunk(chunk)
        XCTAssertTrue(try store.audioAssets.compact(chunk: chunk))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let target = TranscriptSegment(id: "target", meetingID: "meeting", windowID: "later", track: .remote,
                                       startTime: 2, endTime: 3, text: "delete later", speakerID: nil,
                                       isUncertain: false, isProvisional: false, isEdited: false)
        try store.replaceSegments(meetingID: "meeting", windowID: "later", segments: [target], isFinal: true)
        let coordinator = RedactionCoordinator(store: store, paths: paths)
        let preview = try await coordinator.preview(meetingID: "meeting", segmentID: target.id)
        try await coordinator.commit(preview: preview)
        let lease = try store.audioAssets.acquireSync(chunk: chunk)
        XCTAssertEqual(try AudioWindowAssembler.digest(lease.url), chunk.sha256)
    }

    func testRecoveryCompletesIntentStagedAndPublishedDeletions() async throws {
        for initial in [AudioRedaction.State.intent, .staged, .published] {
            let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ECHO_TEST_ROOT"] ?? FileManager.default.currentDirectoryPath + "/tmp/tests")
                .appendingPathComponent("redaction-recovery-\(initial.rawValue)-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = AppPaths(root: root)
            let store = try MeetingStore(paths: paths)
            try store.createMeeting(Meeting(id: "meeting", title: "Recovery", startedAt: Date(), endedAt: Date(),
                                            state: .ready, language: "en", sourceName: "Test",
                                            usesEchoCancellation: false, transcriptRevision: 0))
            let segment = TranscriptSegment(id: "target", meetingID: "meeting", windowID: "window", track: .remote,
                                            startTime: 1, endTime: 2, text: "private passage", speakerID: nil,
                                            isUncertain: false, isProvisional: false, isEdited: false)
            try store.replaceSegments(meetingID: "meeting", windowID: "window", segments: [segment], isFinal: true)
            var redaction = AudioRedaction(meetingID: "meeting", start: 1, end: 2, oldChunks: [])
            try store.saveRedactionIntent(redaction)
            if initial != .intent {
                redaction.state = .staged
                try store.saveStagedRedaction(redaction)
            }
            if initial == .published { try store.publishRedaction(redaction) }
            let coordinator = RedactionCoordinator(store: store, paths: paths)
            try await coordinator.recoverPending()
            try await coordinator.recoverPending()
            XCTAssertTrue(try store.pendingRedactions().isEmpty)
            XCTAssertTrue(try store.segments(meetingID: "meeting").isEmpty)
            XCTAssertTrue(try store.search("private").isEmpty)
            XCTAssertEqual(try store.audioRevision(meetingID: "meeting"), 1)
        }
    }

    func testReliableWordsOutsideDeletedIntervalSurviveAsSeparatePassages() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ECHO_TEST_ROOT"] ?? FileManager.default.currentDirectoryPath + "/tmp/tests")
            .appendingPathComponent("redaction-words-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        let store = try MeetingStore(paths: paths)
        try store.createMeeting(Meeting(id: "meeting", title: "Words", startedAt: Date(), endedAt: Date(),
                                        state: .ready, language: "en", sourceName: "Test",
                                        usesEchoCancellation: false, transcriptRevision: 0))
        let target = TranscriptSegment(id: "target", meetingID: "meeting", windowID: "target-window", track: .remote,
                                       startTime: 1, endTime: 2, text: "delete", speakerID: nil,
                                       isUncertain: false, isProvisional: false, isEdited: false)
        let words = [
            TranscriptWord(id: "a", text: "before", location: 0, length: 6, start: 0.2, end: 0.6, source: .nativeWord),
            TranscriptWord(id: "b", text: "inside", location: 7, length: 6, start: 1.2, end: 1.6, source: .nativeWord),
            TranscriptWord(id: "c", text: "after", location: 14, length: 5, start: 2.2, end: 2.6, source: .nativeWord),
        ]
        let overlapping = TranscriptSegment(id: "overlap", meetingID: "meeting", windowID: "overlap-window", track: .microphone,
                                            startTime: 0, endTime: 3, text: "before inside after", speakerID: nil,
                                            isUncertain: false, isProvisional: false, isEdited: false, words: words)
        try store.replaceSegments(meetingID: "meeting", windowID: "target-window", segments: [target], isFinal: true)
        try store.replaceSegments(meetingID: "meeting", windowID: "overlap-window", segments: [overlapping], isFinal: true)
        let coordinator = RedactionCoordinator(store: store, paths: paths)
        let preview = try await coordinator.preview(meetingID: "meeting", segmentID: "target")
        try await coordinator.commit(preview: preview)
        let retained = try store.segments(meetingID: "meeting").sorted { $0.startTime < $1.startTime }
        XCTAssertEqual(retained.map(\.text), ["before", "after"])
        XCTAssertEqual(retained.map(\.words?.first?.start), [0.2, 2.2])
        XCTAssertTrue(try store.search("inside").isEmpty)
        XCTAssertEqual(try store.search("after").count, 1)
        XCTAssertThrowsError(try store.replaceSegments(meetingID: "meeting", windowID: "target-window",
                                                      segments: [target], isFinal: true),
                             "A late worker result must not restore deleted text")
        let regenerated = TranscriptVersion(id: "regenerated", meetingID: "meeting",
                                            configuration: nil, audioFingerprint: "redacted")
        try store.saveTranscriptVersion(regenerated)
        XCTAssertThrowsError(try store.saveVersionWindow(versionID: "regenerated", windowID: "target-window",
                                                         segments: [target]),
                             "Regeneration must not restore text from deleted audio")
    }

    func testDeletesIntervalOnBothTracksAndTranscriptHistory() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ECHO_TEST_ROOT"] ?? FileManager.default.currentDirectoryPath + "/tmp/tests")
            .appendingPathComponent("redaction-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        let store = try MeetingStore(paths: paths)
        try store.createMeeting(Meeting(id: "meeting", title: "Delete", startedAt: Date(), endedAt: Date(),
                                        state: .ready, language: "en", sourceName: "Test",
                                        usesEchoCancellation: false, transcriptRevision: 0))
        let audioDirectory = paths.meetingDirectory("meeting").appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        for (name, track) in [("remote", AudioTrack.remote), ("microphone", AudioTrack.microphone)] {
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
            buffer.frameLength = 48_000
            for frame in 0..<48_000 { buffer.floatChannelData![0][frame] = frame < 24_000 ? 0.25 : 0.75 }
            let url = audioDirectory.appendingPathComponent(name + ".caf")
            var settings = format.settings; settings[AVLinearPCMIsNonInterleaved] = false
            var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: settings,
                                                     commonFormat: .pcmFormatFloat32, interleaved: false)
            try file?.write(from: buffer); file = nil
            try store.addChunk(.init(id: name, meetingID: "meeting", epochID: "epoch", track: track,
                                     relativePath: "audio/\(name).caf", startTime: 0, duration: 1,
                                     sampleRate: 48_000, frameCount: 48_000,
                                     sha256: try AudioWindowAssembler.digest(url)))
        }
        let target = TranscriptSegment(id: "target", meetingID: "meeting", windowID: "remote-window", track: .remote,
                                       startTime: 0.25, endTime: 0.75, text: "delete these words", speakerID: nil,
                                       isUncertain: false, isProvisional: false, isEdited: false)
        let other = TranscriptSegment(id: "other", meetingID: "meeting", windowID: "mic-window", track: .microphone,
                                      startTime: 0.35, endTime: 0.65, text: "simultaneous words", speakerID: nil,
                                      isUncertain: false, isProvisional: false, isEdited: false)
        try store.replaceSegments(meetingID: "meeting", windowID: "remote-window", segments: [target], isFinal: true)
        try store.replaceSegments(meetingID: "meeting", windowID: "mic-window", segments: [other], isFinal: true)
        let previewTail = TranscriptSegment(id: "preview-tail", meetingID: "meeting", windowID: "preview-window",
                                            track: .remote, startTime: 0.8, endTime: 0.9,
                                            text: "unfinished live preview", speakerID: nil,
                                            isUncertain: true, isProvisional: true, isEdited: false)
        try store.replaceSegments(meetingID: "meeting", windowID: "preview-window",
                                  segments: [previewTail])
        let completedWindow = ProcessingWindow(track: .remote, epochID: "epoch", start: 0,
                                               duration: 1, windowID: "remote-window", provisional: false,
                                               relativePath: "derived/asr-test.wav", ownershipStart: 0,
                                               ownershipEnd: 1)
        try store.enqueue(ProcessingJob(id: "completed-asr", meetingID: "meeting", kind: .transcribe,
                                        status: .completed, payload: String(decoding: try JSONEncoder().encode(completedWindow), as: UTF8.self),
                                        attempts: 1, error: nil, createdAt: Date()))
        var version = TranscriptVersion(id: "history", meetingID: "meeting", configuration: nil, audioFingerprint: "original")
        try store.saveTranscriptVersion(version)
        var historical = target; historical.id = "historical"
        try store.saveVersionWindow(versionID: "history", windowID: "remote-window", segments: [historical])
        version.status = .ready; try store.saveTranscriptVersion(version)
        try store.saveAnnotation(.init(meetingID: "meeting", kind: .bookmark, segmentID: target.id,
                                       startTime: 0.4, endTime: 0.5))
        let coordinator = RedactionCoordinator(store: store, paths: paths)
        let preview = try await coordinator.preview(meetingID: "meeting", segmentID: "target")
        XCTAssertEqual(preview.affectedTracks, Set([.remote, .microphone]))
        XCTAssertEqual(preview.activePassages, 2)
        XCTAssertEqual(preview.historicalPassages, 1)
        try await coordinator.commit(preview: preview)
        XCTAssertEqual(try store.chunks(meetingID: "meeting").count, 4)
        XCTAssertTrue(try store.segments(meetingID: "meeting").isEmpty)
        XCTAssertTrue(try store.versionSegments(versionID: "history").isEmpty)
        XCTAssertTrue(try store.annotations(meetingID: "meeting").isEmpty)
        XCTAssertTrue(try store.search("delete").isEmpty)
        XCTAssertTrue(try store.pendingRedactions().isEmpty)
        XCTAssertEqual(try store.audioRevision(meetingID: "meeting"), 1)
        XCTAssertFalse(try store.redactions(meetingID: "meeting").allSatisfy(\.preserveExistingTranscript),
                       "A provisional tail still requires final recognition")
        XCTAssertEqual(try store.redactions(meetingID: "meeting").first?.completedSpeechWindows.count, 1)
        let lateURL = audioDirectory.appendingPathComponent("late.caf")
        try Data("late recovered bytes".utf8).write(to: lateURL)
        let late = CapturedChunk(id: "late", meetingID: "meeting", epochID: "late-epoch", track: .microphone,
                                 relativePath: "audio/late.caf", startTime: 0.4, duration: 0.1,
                                 sampleRate: 48_000, frameCount: 4_800,
                                 sha256: try AudioWindowAssembler.digest(lateURL))
        XCTAssertThrowsError(try store.addChunk(late), "Recovery must not restore deleted audio")
        let retainedMicrophone = try store.chunks(meetingID: "meeting").filter { $0.track == .microphone }
            .sorted { $0.startTime < $1.startTime }
        XCTAssertEqual(retainedMicrophone.count, 2)
        XCTAssertNotEqual(retainedMicrophone[0].epochID, retainedMicrophone[1].epochID,
                          "AEC must start a new adaptation epoch after the deleted interval")
        let aecWindows = AECWindowPlanner.windows(meetingID: "meeting", raw: try store.chunks(meetingID: "meeting"), final: true)
        XCTAssertEqual(aecWindows.filter { $0.duration > 0 }.count, 2)
        for chunk in try store.chunks(meetingID: "meeting") {
            XCTAssertTrue(chunk.startTime + chunk.duration <= 0.25 || chunk.startTime >= 0.75)
            let lease = try store.audioAssets.acquireSync(chunk: chunk)
            let file = try AVAudioFile(forReading: lease.url)
            XCTAssertEqual(file.length, chunk.frameCount)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buffer)
            XCTAssertEqual(buffer.floatChannelData![0][0].bitPattern,
                           (chunk.startTime < 0.25 ? Float(0.25) : Float(0.75)).bitPattern)
        }
    }
}
