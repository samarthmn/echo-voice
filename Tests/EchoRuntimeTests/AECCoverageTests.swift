import XCTest
import EchoCore
import EchoIntelligence
@testable import EchoRuntime

final class AECCoverageTests: XCTestCase {
    private func chunk(_ id: String, epoch: String, track: AudioTrack, start: Double, duration: Double) -> CapturedChunk {
        CapturedChunk(id: id, meetingID: "meeting", epochID: epoch, track: track, relativePath: "audio/\(id).caf", startTime: start, duration: duration, sampleRate: 16000, frameCount: Int64(duration * 16000), sha256: String(repeating: "0", count: 64))
    }
    func testRedactionRepairPlansOnlyMissingCleanAudioWithNewWorkerIdentity() {
        let near = [chunk("before", epoch: "mic", track: .microphone, start: 0, duration: 5),
                    chunk("after", epoch: "mic-new", track: .microphone, start: 7, duration: 8)]
        let clean = [chunk("clean-before", epoch: "mic", track: .cleanMicrophone, start: 0, duration: 5)]
        let reference = [chunk("remote", epoch: "remote", track: .remote, start: 0, duration: 15)]
        let missing = AECRepairPlanner.missingNearChunks(near: near, clean: clean)
        XCTAssertEqual(missing.map(\.startTime), [7])
        XCTAssertEqual(missing.map(\.duration), [8])
        let repaired = AECWindowPlanner.windows(meetingID: "meeting", raw: missing + reference,
                                                final: true, stateNamespace: "redaction-1")
        XCTAssertEqual(repaired.filter { $0.duration > 0 }.map(\.start), [7, 12])
        XCTAssertEqual(repaired.filter { $0.final == true }.count, 1)
        let old = AECWindowPlanner.windows(meetingID: "meeting", raw: near + reference, final: true)
        XCTAssertTrue(Set(repaired.map(\.windowID)).isDisjoint(with: Set(old.map(\.windowID))))
    }
    func testGoodEpochDoesNotHideLaterMissingReferenceEpoch() {
        let near = [chunk("n1", epoch: "a", track: .microphone, start: 0, duration: 5), chunk("n2", epoch: "b", track: .microphone, start: 10, duration: 3)]
        let clean = [chunk("c1", epoch: "a", track: .cleanMicrophone, start: 0, duration: 5)]
        let gaps = AECCoverageAudit.uncovered(near: near, clean: clean)
        XCTAssertEqual(gaps, [.init(epochID: "b", start: 10, end: 13)])
    }
    func testReportsHeadTailAndInternalMissingIntervals() {
        let near = [chunk("n", epoch: "a", track: .microphone, start: 0, duration: 20)]
        let clean = [chunk("c1", epoch: "a", track: .cleanMicrophone, start: 1, duration: 4), chunk("c2", epoch: "a", track: .cleanMicrophone, start: 8, duration: 10)]
        XCTAssertEqual(AECCoverageAudit.uncovered(near: near, clean: clean), [.init(epochID: "a", start: 0, end: 1), .init(epochID: "a", start: 5, end: 8), .init(epochID: "a", start: 18, end: 20)])
    }
    func testAdjacentCleanChunksAndTenMillisecondFrameTolerance() {
        let near = [chunk("n", epoch: "a", track: .microphone, start: 0, duration: 10)]
        let clean = [chunk("c1", epoch: "a", track: .cleanMicrophone, start: 0.005, duration: 4.995), chunk("c2", epoch: "a", track: .cleanMicrophone, start: 5, duration: 4.995)]
        XCTAssertTrue(AECCoverageAudit.uncovered(near: near, clean: clean).isEmpty)
    }
    func testCoverageCannotBeBorrowedFromDifferentEpoch() {
        let near = [chunk("n", epoch: "b", track: .microphone, start: 0, duration: 5)]
        let clean = [chunk("c", epoch: "a", track: .cleanMicrophone, start: 0, duration: 5)]
        XCTAssertEqual(AECCoverageAudit.uncovered(near: near, clean: clean), [.init(epochID: "b", start: 0, end: 5)])
    }
    func testPreparationMatchesRemoteByTimelineAcrossDifferentTrackEpochs() {
        let raw = [
            chunk("m1", epoch: "mic-a", track: .microphone, start: 0, duration: 5),
            chunk("m2", epoch: "mic-b", track: .microphone, start: 5, duration: 5),
            chunk("r1", epoch: "remote-a", track: .remote, start: 0, duration: 10),
        ]
        let windows = AECWindowPlanner.windows(meetingID: "meeting", raw: raw, final: true)
        let audio = windows.filter { $0.duration > 0 }
        XCTAssertEqual(audio.map(\.epochID), ["mic-a", "mic-b"])
        XCTAssertEqual(audio.map(\.start), [0, 5])
        XCTAssertEqual(audio.map(\.duration), [5, 5])
        XCTAssertEqual(windows.filter { $0.final == true }.count, 2)
    }
    func testMissingReferenceDoesNotScheduleFabricatedFarAudio() {
        let raw = [chunk("m", epoch: "mic", track: .microphone, start: 0, duration: 5),
                   chunk("r", epoch: "remote", track: .remote, start: 0, duration: 2)]
        let windows = AECWindowPlanner.windows(meetingID: "meeting", raw: raw, final: true)
        XCTAssertEqual(windows.filter { $0.duration > 0 }.map(\.duration), [2])
        XCTAssertTrue(windows.allSatisfy { $0.start + $0.duration <= 2 })
    }
    func testLaterReferenceCoverageStillSchedulesAEC() {
        let raw = [
            chunk("m1", epoch: "mic", track: .microphone, start: 0, duration: 5),
            chunk("m2", epoch: "mic", track: .microphone, start: 5, duration: 5),
            chunk("r", epoch: "remote", track: .remote, start: 5, duration: 5),
        ]
        let windows = AECWindowPlanner.windows(meetingID: "meeting", raw: raw, final: true)
        XCTAssertEqual(windows.filter { $0.duration > 0 }.map(\.start), [5])
        XCTAssertEqual(windows.filter { $0.final == true }.count, 1)
    }
    func testLiveTranscriptionOffStillSchedulesAECPreparation() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ECHO_TEST_ROOT"] ?? FileManager.default.currentDirectoryPath + "/tmp/tests")
            .appendingPathComponent("aec-live-off-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        let store = try MeetingStore(paths: paths)
        try store.createMeeting(Meeting(id: "meeting", title: "Live off", startedAt: Date(), endedAt: nil,
                                        state: .recording, language: "en", sourceName: "Test",
                                        usesEchoCancellation: true, transcriptRevision: 0))
        try store.setInitialLiveTranscriptionPolicy(meetingID: "meeting", enabled: false)
        for item in [chunk("m", epoch: "mic", track: .microphone, start: 0, duration: 5),
                     chunk("m2", epoch: "mic", track: .microphone, start: 5, duration: 5),
                     chunk("r", epoch: "remote", track: .remote, start: 0, duration: 5),
                     chunk("r2", epoch: "remote", track: .remote, start: 5, duration: 5)] {
            let asset = try paths.resolveMeetingAsset(meetingID: "meeting", relativePath: item.relativePath)
            try FileManager.default.createDirectory(at: asset.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([0]).write(to: asset)
            try store.addChunk(item)
        }
        let processor = MeetingProcessor(store: store, paths: paths, service: LocalService(paths: paths),
                                         intelligence: LocalIntelligence(modelsURL: paths.modelsURL))
        await processor.startLive(meetingID: "meeting", onUpdate: { _ in })
        for _ in 0..<20 {
            if try store.jobs(meetingID: "meeting").contains(where: { $0.kind == .prepareAudio }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        await processor.stopLive()
        XCTAssertTrue(try store.jobs(meetingID: "meeting").contains(where: { $0.kind == .prepareAudio }))
        XCTAssertFalse(try store.jobs(meetingID: "meeting").contains(where: { $0.kind == .transcribe }))
    }
    func testCoverageAuditPersistsFailureAndGapThenResolvesIdempotently() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ECHO_TEST_ROOT"] ?? FileManager.default.currentDirectoryPath + "/tmp/tests").appendingPathComponent("coverage-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        let store = try MeetingStore(paths: paths)
        try store.createMeeting(Meeting(id: "meeting", title: "Test", startedAt: Date(), endedAt: nil, state: .finalizing, language: "en", sourceName: "Synthetic", usesEchoCancellation: true, transcriptRevision: 0))
        let processor = MeetingProcessor(store: store, paths: paths, service: LocalService(paths: paths), intelligence: LocalIntelligence(modelsURL: paths.modelsURL))
        func save(_ chunk: CapturedChunk) throws {
            let url = try paths.resolveMeetingAsset(meetingID: "meeting", relativePath: chunk.relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([0]).write(to: url) // metadata-only audit never decodes or runs audio
            try store.addChunk(chunk)
        }
        try save(chunk("n1", epoch: "a", track: .microphone, start: 0, duration: 5))
        try save(chunk("c1", epoch: "a", track: .cleanMicrophone, start: 0, duration: 5))
        try save(chunk("n2", epoch: "b", track: .microphone, start: 10, duration: 3))
        try await processor.auditPreparedCoverage(meetingID: "meeting")
        try await processor.auditPreparedCoverage(meetingID: "meeting")
        let failed = try store.jobs(meetingID: "meeting")
        XCTAssertEqual(failed.count, 1)
        XCTAssertEqual(failed[0].status, .failed)
        XCTAssertTrue(failed[0].error?.contains("Raw microphone audio is retained") == true)
        XCTAssertEqual(try store.gaps(meetingID: "meeting").count, 1)
        try save(chunk("c2", epoch: "b", track: .cleanMicrophone, start: 10, duration: 3))
        try await processor.auditPreparedCoverage(meetingID: "meeting")
        XCTAssertEqual(try store.jobs(meetingID: "meeting")[0].status, .cancelled)
        XCTAssertTrue(try store.gaps(meetingID: "meeting")[0].reason.hasPrefix("Resolved"))
    }

}
