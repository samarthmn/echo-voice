import AVFoundation
import XCTest
@testable import EchoCore
import EchoIntelligence
@testable import EchoRuntime

final class MeetingProcessorRegressionTests: XCTestCase {
    private func fixture(aec: Bool) throws -> (AppPaths, MeetingStore, FixtureAudioService, MeetingProcessor) {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ECHO_TEST_ROOT"] ?? FileManager.default.currentDirectoryPath + "/tmp/tests")
            .appendingPathComponent("processor-regression-\(UUID().uuidString)")
        let paths = AppPaths(root: root)
        let store = try MeetingStore(paths: paths)
        try store.createMeeting(Meeting(id: "meeting", title: "Synthetic", startedAt: Date(), endedAt: nil,
                                        state: .recording, language: "en", sourceName: "Fixture",
                                        usesEchoCancellation: aec, transcriptRevision: 0))
        try store.setConfiguration(meetingID: "meeting", configuration: ProcessingConfiguration(
            speech: ModelSelection(id: "whisper", revision: "fixture")))
        let service = FixtureAudioService(paths: paths)
        let processor = MeetingProcessor(store: store, paths: paths, service: service,
                                         intelligence: LocalIntelligence(modelsURL: paths.modelsURL))
        return (paths, store, service, processor)
    }

    private func saveAudio(_ store: MeetingStore, id: String, epoch: String, track: AudioTrack,
                           start: Double, duration: Double, path: String? = nil) throws {
        let relative = path ?? "audio/\(id).wav"
        let url = try store.paths.resolveMeetingAsset(meetingID: "meeting", relativePath: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!
        let frames = AVAudioFrameCount((duration * 16_000).rounded())
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(1, frames))!
        buffer.frameLength = frames
        if frames > 0 { memset(buffer.int16ChannelData![0], 0, Int(frames) * 2) }
        do {
            let writer = try AVAudioFile(forWriting: url, settings: format.settings,
                                         commonFormat: .pcmFormatInt16, interleaved: false)
            try writer.write(from: buffer)
        }
        try store.addChunk(CapturedChunk(id: id, meetingID: "meeting", epochID: epoch, track: track,
            relativePath: relative, startTime: start, duration: duration, sampleRate: 16_000,
            frameCount: Int64(frames), sha256: try AudioWindowAssembler.digest(url)))
    }

    func testFinalizationCancellationKeepsProcessingStateAndDurableQueue() async throws {
        let (paths, store, service, processor) = try fixture(aec: false)
        defer { try? store.database.close(); try? FileManager.default.removeItem(at: paths.root) }
        try saveAudio(store, id: "mic", epoch: "mic", track: .microphone, start: 0, duration: 5)
        try store.enqueueProcessing(meetingID: "meeting")
        await service.holdNextSpeech()
        let task = Task { try await processor.finalize(meetingID: "meeting", onUpdate: { _ in }) }
        for _ in 0..<100 {
            if await service.hasHeldSpeech { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let held = await service.hasHeldSpeech
        XCTAssertTrue(held)
        await processor.cancel()
        do { try await task.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        XCTAssertEqual(try store.meeting(id: "meeting")?.state, .finalizing)
        XCTAssertEqual(try store.processingQueue().map(\.meetingID), ["meeting"])
        let job = try XCTUnwrap(store.jobs(meetingID: "meeting").first { $0.kind == .transcribe })
        XCTAssertEqual(job.status, .pending)
        XCTAssertEqual(job.attempts, 0)
        try await processor.finalize(meetingID: "meeting", onUpdate: { _ in })
        XCTAssertEqual(try store.meeting(id: "meeting")?.state, .ready)
    }

    func testFinalizationRestoresEveryPrunedLiveEpochTail() async throws {
        let (paths, store, service, processor) = try fixture(aec: false)
        defer { try? store.database.close(); try? FileManager.default.removeItem(at: paths.root) }
        for (id, epoch, start) in [("a1", "a", 0.0), ("a2", "a", 5.0),
                                   ("b1", "b", 100.0), ("b2", "b", 105.0)] {
            try saveAudio(store, id: id, epoch: epoch, track: .microphone, start: start, duration: 5)
        }
        await processor.startLive(meetingID: "meeting", onUpdate: { _ in })
        for _ in 0..<100 {
            if await service.speechCount > 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        await processor.stopLive()
        try await processor.finalize(meetingID: "meeting", onUpdate: { _ in })
        let completed = try store.jobs(meetingID: "meeting").filter { $0.kind == .transcribe && $0.status == .completed }
            .map { try JSONDecoder().decode(ProcessingWindow.self, from: Data($0.payload.utf8)) }
            .filter { !$0.provisional }
        XCTAssertEqual(Set(completed.map(\.epochID)), Set(["a", "b"]))
        XCTAssertEqual(try store.meeting(id: "meeting")?.state, .ready)
    }

    func testFinalizationRetriesExhaustedRecognitionInterruptedByCrash() async throws {
        let (paths, store, _, processor) = try fixture(aec: false)
        defer { try? store.database.close(); try? FileManager.default.removeItem(at: paths.root) }
        try saveAudio(store, id: "mic", epoch: "mic", track: .microphone, start: 0, duration: 5)
        let configuration = try XCTUnwrap(store.configuration(meetingID: "meeting"))
        var window = try XCTUnwrap(ProcessingIdentity.speechWindows(meetingID: "meeting", chunks: store.chunks(meetingID: "meeting"), final: true).first)
        window.windowID = ProcessingIdentity.id(window.windowID, configuration.id, "recording")
        window.relativePath = "derived/asr-" + ProcessingIdentity.id(window.windowID, String(window.duration), String(window.provisional)) + ".wav"
        window.configuration = configuration
        let id = ProcessingIdentity.jobID(window, kind: .transcribe)
        try store.enqueue(ProcessingJob(id: id, meetingID: "meeting", kind: .transcribe, status: .running,
                                        payload: String(decoding: try JSONEncoder().encode(window), as: UTF8.self),
                                        attempts: 3, error: nil, createdAt: Date()))
        try store.recoverRunningJobs()
        try await processor.finalize(meetingID: "meeting", onUpdate: { _ in })
        XCTAssertEqual(try store.jobs(meetingID: "meeting").first(where: { $0.id == id })?.status, .completed)
        XCTAssertEqual(try store.segments(meetingID: "meeting").map(\.text), ["Synthetic speech"])
        XCTAssertEqual(try store.meeting(id: "meeting")?.state, .ready)
    }

    func testStopLiveWhileHealthIsPendingDoesNotSubmitRecognition() async throws {
        let (paths, store, service, processor) = try fixture(aec: false)
        defer { try? store.database.close(); try? FileManager.default.removeItem(at: paths.root) }
        try saveAudio(store, id: "mic", epoch: "mic", track: .microphone, start: 0, duration: 5)
        await service.holdNextHealth()
        await processor.startLive(meetingID: "meeting", onUpdate: { _ in })
        for _ in 0..<100 {
            if await service.hasHeldHealth { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let held = await service.hasHeldHealth
        XCTAssertTrue(held)
        try await processor.stopLiveTranscription(meetingID: "meeting", effectiveTime: 2)
        await service.releaseHealth()
        await processor.stopLive()
        let submissions = await service.speechCount
        XCTAssertEqual(submissions, 0)
        XCTAssertTrue(try store.segments(meetingID: "meeting").isEmpty)
    }

    func testExactCleanCoverageStillCompletesTerminalAECJob() async throws {
        let (paths, store, service, processor) = try fixture(aec: true)
        defer { try? store.database.close(); try? FileManager.default.removeItem(at: paths.root) }
        try saveAudio(store, id: "mic", epoch: "mic", track: .microphone, start: 0, duration: 5)
        try saveAudio(store, id: "remote", epoch: "remote", track: .remote, start: 0, duration: 5)
        try await processor.finalize(meetingID: "meeting", onUpdate: { _ in })
        let calls = await service.preparationCalls
        XCTAssertEqual(calls.map(\.final), [false, true])
        let finalJobs = try store.jobs(meetingID: "meeting").filter { $0.kind == .prepareAudio }
        XCTAssertEqual(finalJobs.count, 2)
        XCTAssertTrue(finalJobs.allSatisfy { $0.status == .completed })
        XCTAssertEqual(try store.meeting(id: "meeting")?.state, .ready)
    }

    func testStoppingLiveRecognitionDoesNotConsumeAttemptsAndFinalizationStillCompletes() async throws {
        let (paths, store, service, processor) = try fixture(aec: false)
        defer { try? store.database.close(); try? FileManager.default.removeItem(at: paths.root) }
        try saveAudio(store, id: "mic", epoch: "mic", track: .microphone, start: 0, duration: 5)
        await service.holdNextSpeech()
        await processor.startLive(meetingID: "meeting", onUpdate: { _ in })
        for _ in 0..<100 {
            if await service.hasHeldSpeech { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let held = await service.hasHeldSpeech
        XCTAssertTrue(held)
        try await processor.stopLiveTranscription(meetingID: "meeting", effectiveTime: 2)
        for _ in 0..<100 {
            if try store.jobs(meetingID: "meeting").contains(where: { $0.kind == .transcribe && $0.attempts == 0 && $0.status == .pending }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        await processor.stopLive()
        let cancelled = try XCTUnwrap(store.jobs(meetingID: "meeting").first { $0.kind == .transcribe })
        XCTAssertEqual(cancelled.attempts, 0)
        XCTAssertEqual(cancelled.status, .pending)
        XCTAssertEqual(try store.liveTranscriptionPolicy(meetingID: "meeting").stoppedAt, 2)
        try await processor.finalize(meetingID: "meeting", onUpdate: { _ in })
        XCTAssertFalse(try store.segments(meetingID: "meeting").isEmpty)
        XCTAssertEqual(try store.meeting(id: "meeting")?.state, .ready)
    }

    func testRestartedRedactionRepairDoesNotCreateOverlappingWorkerRuns() async throws {
        let (paths, store, service, processor) = try fixture(aec: true)
        defer { try? store.database.close(); try? FileManager.default.removeItem(at: paths.root) }
        var redaction = AudioRedaction(meetingID: "meeting", start: 50, end: 51, oldChunks: [])
        try store.saveRedactionIntent(redaction)
        redaction.state = .staged
        try store.saveStagedRedaction(redaction)
        try store.publishRedaction(redaction)
        redaction.state = .published
        try store.completeRedaction(redaction)
        try saveAudio(store, id: "mic", epoch: "mic", track: .microphone, start: 7, duration: 8)
        try saveAudio(store, id: "remote", epoch: "remote", track: .remote, start: 7, duration: 8)
        let raw = try store.chunks(meetingID: "meeting")
        let windows = AECWindowPlanner.windows(meetingID: "meeting", raw: raw, final: true,
                                                stateNamespace: "redaction-1")
        for window in windows {
            let id = ProcessingIdentity.jobID(window, kind: .prepareAudio)
            let completed = window.sequence == 0
            try store.enqueue(ProcessingJob(id: id, meetingID: "meeting", kind: .prepareAudio,
                status: completed ? .completed : .pending,
                payload: String(decoding: try JSONEncoder().encode(window), as: UTF8.self),
                attempts: completed ? 1 : 0, error: nil, createdAt: Date()))
            if completed {
                try saveAudio(store, id: id, epoch: "mic", track: .cleanMicrophone,
                              start: 7, duration: 5, path: window.relativePath)
            }
        }
        try await processor.finalize(meetingID: "meeting", onUpdate: { _ in })
        let calls = await service.preparationCalls
        XCTAssertEqual(calls.map(\.sequence), [1, 2])
        XCTAssertEqual(Set(calls.map(\.epochID)), Set(windows.compactMap(\.aecStateID)))
        let clean = try store.chunks(meetingID: "meeting", track: .cleanMicrophone).sorted { $0.startTime < $1.startTime }
        XCTAssertEqual(clean.count, 2)
        XCTAssertEqual(clean.reduce(0) { $0 + $1.duration }, 8, accuracy: 0.001)
        XCTAssertLessThanOrEqual(clean[0].startTime + clean[0].duration, clean[1].startTime)
    }

    func testReadyRedactedMeetingRepairsAECWithoutReplacingReviewedText() async throws {
        let (paths, store, service, processor) = try fixture(aec: true)
        defer { try? store.database.close(); try? FileManager.default.removeItem(at: paths.root) }
        for track in [AudioTrack.microphone, .remote, .cleanMicrophone] {
            try saveAudio(store, id: track.rawValue, epoch: "mic", track: track,
                          start: 0, duration: 15)
        }
        let target = TranscriptSegment(id: "target", meetingID: "meeting", windowID: "old", track: .remote,
                                       startTime: 5, endTime: 7, text: "Delete synthetic passage",
                                       speakerID: nil, isUncertain: false, isProvisional: false, isEdited: false)
        let retained = TranscriptSegment(id: "retained", meetingID: "meeting", windowID: "old", track: .remote,
                                         startTime: 10, endTime: 11, text: "Original synthetic passage",
                                         speakerID: nil, isUncertain: false, isProvisional: false, isEdited: false)
        try store.replaceSegments(meetingID: "meeting", windowID: "old", segments: [target, retained], isFinal: true)
        try store.editSegment(id: "retained", text: "My reviewed correction")
        var meeting = try XCTUnwrap(store.meeting(id: "meeting"))
        meeting.state = .ready; meeting.endedAt = Date()
        try store.updateMeeting(meeting)
        let redactor = RedactionCoordinator(store: store, paths: paths)
        let preview = try await redactor.preview(meetingID: "meeting", segmentID: "target")
        try await redactor.commit(preview: preview)
        XCTAssertFalse(AECCoverageAudit.uncovered(near: try store.speakerphoneMicrophoneChunks(meetingID: "meeting"),
                                                 clean: try store.chunks(meetingID: "meeting", track: .cleanMicrophone)).isEmpty)
        try await processor.finalize(meetingID: "meeting", onUpdate: { _ in })
        XCTAssertTrue(AECCoverageAudit.uncovered(near: try store.speakerphoneMicrophoneChunks(meetingID: "meeting"),
                                                clean: try store.chunks(meetingID: "meeting", track: .cleanMicrophone)).isEmpty)
        XCTAssertEqual(try store.segments(meetingID: "meeting").map(\.text), ["My reviewed correction"])
        let speechCount = await service.speechCount
        XCTAssertEqual(speechCount, 0)
        XCTAssertEqual(try store.meeting(id: "meeting")?.state, .ready)
    }
}

private actor FixtureAudioService: MeetingAudioService {
    struct PreparationCall: Sendable { let epochID: String; let sequence: Int; let final: Bool }
    let paths: AppPaths
    var preparationCalls: [PreparationCall] = []
    var speechCount = 0
    private var shouldHoldSpeech = false
    private var heldSpeech: (String, CheckedContinuation<Void, Error>)?
    private var shouldHoldHealth = false
    private var heldHealth: CheckedContinuation<Void, Never>?
    var hasHeldSpeech: Bool { heldSpeech != nil }
    init(paths: AppPaths) { self.paths = paths }
    func holdNextSpeech() { shouldHoldSpeech = true }
    var hasHeldHealth: Bool { heldHealth != nil }
    func holdNextHealth() { shouldHoldHealth = true }
    func releaseHealth() { heldHealth?.resume(); heldHealth = nil }
    func health() async throws -> ServiceHealth {
        if shouldHoldHealth {
            shouldHoldHealth = false
            await withCheckedContinuation { heldHealth = $0 }
        }
        return try JSONDecoder().decode(ServiceHealth.self, from: Data(#"{"status":"ready","capabilities":{"transcribe":true,"prepare_audio":true,"diarize":false},"models":{},"speech_models":{"whisper":true,"parakeet":true}}"#.utf8))
    }
    func transcribe(_ body: [String: Any]) async throws -> SpeechResult {
        speechCount += 1
        if shouldHoldSpeech {
            shouldHoldSpeech = false
            try await withCheckedThrowingContinuation { continuation in
                heldSpeech = (body["job_id"] as! String, continuation)
            }
        }
        let input = try paths.resolveMeetingAsset(meetingID: body["meeting_id"] as! String,
                                                  relativePath: body["relative_path"] as! String)
        let audio = try AVAudioFile(forReading: input)
        let duration = Double(audio.length) / audio.fileFormat.sampleRate
        return SpeechResult(segments: [.init(start: 0, end: min(1, duration), text: "Synthetic speech",
            words: nil, original_text: nil, uncertain: nil, corrections: nil, confidence: nil)])
    }
    func prepareAudio(_ body: [String: Any]) async throws -> PrepareAudioResult {
        preparationCalls.append(.init(epochID: body["epoch_id"] as! String,
                                       sequence: body["sequence"] as! Int, final: body["final"] as! Bool))
        let meetingID = body["meeting_id"] as! String
        let input = try paths.resolveMeetingAsset(meetingID: meetingID, relativePath: body["near_path"] as! String)
        let relative = body["output_path"] as! String
        let output = try paths.resolveMeetingAsset(meetingID: meetingID, relativePath: relative)
        try FileManager.default.copyItem(at: input, to: output)
        let audio = try AVAudioFile(forReading: output)
        return PrepareAudioResult(sample_rate: audio.fileFormat.sampleRate, frame_count: audio.length,
                                  relative_path: relative)
    }
    func diarize(_ body: [String: Any]) async throws -> DiarizationResult { DiarizationResult(turns: [], partial: false) }
    func cancel(jobID: String) async {
        if let heldSpeech, heldSpeech.0 == jobID {
            self.heldSpeech = nil
            heldSpeech.1.resume(throwing: CancellationError())
        }
    }
    func unload() async {}
}
