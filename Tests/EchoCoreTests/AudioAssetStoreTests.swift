import Foundation
import XCTest
import GRDB
@testable import EchoCore

final class AudioAssetStoreTests: XCTestCase {
    func testCompactionCannotMutateDeletionQuarantinedMeeting() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ECHO_TEST_ROOT"] ?? FileManager.default.currentDirectoryPath + "/tmp/tests")
            .appendingPathComponent("asset-compaction-quarantine-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        var store = try MeetingStore(paths: paths)
        try store.createMeeting(Meeting(id: "meeting", title: "Quarantined", startedAt: Date(), endedAt: Date(),
                                        state: .ready, language: "en", sourceName: "Synthetic",
                                        usesEchoCancellation: false, transcriptRevision: 0))
        let file = try paths.resolveMeetingAsset(meetingID: "meeting", relativePath: "audio/chunk.caf")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data(repeating: 3, count: 100_000)
        try bytes.write(to: file)
        let chunk = CapturedChunk(id: "chunk", meetingID: "meeting", epochID: "epoch", track: .remote,
                                  relativePath: "audio/chunk.caf", startTime: 0, duration: 1,
                                  sampleRate: 48_000, frameCount: 48_000, sha256: try MeetingStore.sha256(file))
        try store.addChunk(chunk)
        let journal = root.appendingPathComponent("Deleted Meetings/meeting-\(UUID().uuidString)/tombstone.json")
        try FileManager.default.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("damaged journal".utf8).write(to: journal)
        store = try MeetingStore(paths: paths, deferAssetRecovery: true)
        XCTAssertEqual(store.deletionRecoveryIssues.map(\.meetingID), ["meeting"])
        do {
            _ = try await AudioCompactor(store: store).compact(meetingID: "meeting")
            XCTFail("Compaction must require deletion recovery")
        } catch EchoCoreError.deletionRecoveryRequired { }
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path + ".lzfse"))
    }

    func testDecodedCacheStaysBoundedAcrossProcessRestarts() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ECHO_TEST_ROOT"] ?? FileManager.default.currentDirectoryPath + "/tmp/tests")
            .appendingPathComponent("asset-cache-restarts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        var store: MeetingStore? = try MeetingStore(paths: paths)
        try store!.createMeeting(Meeting(id: "meeting", title: "Cache", startedAt: Date(), endedAt: Date(),
                                         state: .ready, language: "en", sourceName: "Test",
                                         usesEchoCancellation: false, transcriptRevision: 0))
        var chunks: [CapturedChunk] = []
        for index in 0..<5 {
            let relative = "audio/\(index).caf"
            let file = try paths.resolveMeetingAsset(meetingID: "meeting", relativePath: relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: UInt8(index), count: 100_000).write(to: file)
            let chunk = CapturedChunk(id: "chunk-\(index)", meetingID: "meeting", epochID: "epoch", track: .remote,
                                      relativePath: relative, startTime: Double(index), duration: 1,
                                      sampleRate: 48_000, frameCount: 48_000, sha256: try MeetingStore.sha256(file))
            try store!.addChunk(chunk); XCTAssertTrue(try store!.audioAssets.compact(chunk: chunk)); chunks.append(chunk)
        }
        for chunk in chunks {
            store = nil
            store = try MeetingStore(paths: paths)
            do {
                let lease = try store!.audioAssets.acquireSync(chunk: chunk)
                XCTAssertEqual(try MeetingStore.sha256(lease.url), chunk.sha256)
            }
            let files = try FileManager.default.contentsOfDirectory(at: paths.meetingDirectory("meeting").appendingPathComponent("decoded-cache"), includingPropertiesForKeys: nil)
            XCTAssertLessThanOrEqual(files.count, 3)
        }
    }

    func testDeletionPurgesDecodedCacheAfterProcessRestart() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ECHO_TEST_ROOT"] ?? FileManager.default.currentDirectoryPath + "/tmp/tests")
            .appendingPathComponent("asset-deletion-recovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var store = try MeetingStore(paths: AppPaths(root: root))
        try store.createMeeting(Meeting(id: "meeting", title: "Delete", startedAt: Date(), endedAt: Date(),
                                        state: .ready, language: "en", sourceName: "Test",
                                        usesEchoCancellation: false, transcriptRevision: 0))
        let file = try store.paths.resolveMeetingAsset(meetingID: "meeting", relativePath: "audio/chunk.caf")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 4, count: 400_000).write(to: file)
        let chunk = CapturedChunk(id: "chunk", meetingID: "meeting", epochID: "epoch", track: .remote,
                                  relativePath: "audio/chunk.caf", startTime: 0, duration: 1,
                                  sampleRate: 48_000, frameCount: 48_000, sha256: try MeetingStore.sha256(file))
        try store.addChunk(chunk)
        XCTAssertTrue(try store.audioAssets.compact(chunk: chunk))
        let cached = try store.audioAssets.acquireSync(chunk: chunk).url
        XCTAssertTrue(FileManager.default.fileExists(atPath: cached.path))
        store = try MeetingStore(paths: AppPaths(root: root))
        try store.audioAssets.purgeDeleted(chunk: chunk)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cached.path))
    }

    func testCompactionPreservesCanonicalBytesThroughReopenAndExport() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ECHO_TEST_ROOT"] ?? FileManager.default.currentDirectoryPath + "/tmp/tests")
            .appendingPathComponent("asset-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var store = try MeetingStore(paths: AppPaths(root: root))
        try store.createMeeting(Meeting(id: "meeting", title: "Lossless", startedAt: Date(), endedAt: Date(),
                                        state: .ready, language: "en", sourceName: "Test",
                                        usesEchoCancellation: false, transcriptRevision: 0))
        let file = try store.paths.resolveMeetingAsset(meetingID: "meeting", relativePath: "audio/first.caf")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data(repeating: 0, count: 400_000) + Data((0..<100_000).map { UInt8($0 & 255) })
        try original.write(to: file)
        let chunk = CapturedChunk(id: "first", meetingID: "meeting", epochID: "epoch", track: .remote,
                                  relativePath: "audio/first.caf", startTime: 0, duration: 1,
                                  sampleRate: 48_000, frameCount: 48_000,
                                  sha256: try MeetingStore.sha256(file))
        try store.addChunk(chunk)
        XCTAssertTrue(try store.audioAssets.compact(chunk: chunk))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        do {
            let lease = try store.audioAssets.acquireSync(chunk: chunk)
            XCTAssertEqual(try Data(contentsOf: lease.url), original)
        }
        store = try MeetingStore(paths: AppPaths(root: root))
        do {
            let lease = try store.audioAssets.acquireSync(chunk: chunk)
            XCTAssertEqual(try Data(contentsOf: lease.url), original)
        }
        let exportRoot = root.appendingPathComponent("exports")
        let exported = try MeetingExporter(store: store).export(meetingID: "meeting", to: exportRoot)
        XCTAssertEqual(try Data(contentsOf: exported.appendingPathComponent("audio/remote/first.caf")), original)
    }

    func testInterruptedPublicationKeepsOriginalAndClearsStaging() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ECHO_TEST_ROOT"] ?? FileManager.default.currentDirectoryPath + "/tmp/tests")
            .appendingPathComponent("asset-publication-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var store = try MeetingStore(paths: AppPaths(root: root))
        try store.createMeeting(Meeting(id: "meeting", title: "Recovery", startedAt: Date(), endedAt: Date(),
                                        state: .ready, language: "en", sourceName: "Test",
                                        usesEchoCancellation: false, transcriptRevision: 0))
        let original = try store.paths.resolveMeetingAsset(meetingID: "meeting", relativePath: "audio/chunk.caf")
        try FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 10_000).write(to: original)
        let chunk = CapturedChunk(id: "chunk", meetingID: "meeting", epochID: "epoch", track: .remote,
                                  relativePath: "audio/chunk.caf", startTime: 0, duration: 1,
                                  sampleRate: 48_000, frameCount: 48_000,
                                  sha256: try MeetingStore.sha256(original))
        try store.addChunk(chunk)
        let packed = try store.paths.resolveMeetingAsset(meetingID: "meeting", relativePath: "audio/chunk.caf.lzfse")
        try Data(repeating: 9, count: 100).write(to: packed)
        try store.database.write { db in
            try db.execute(sql: """
                INSERT INTO audio_representations(meeting_id,chunk_id,codec,codec_version,stored_path,stored_size,decoded_size,stored_sha256,canonical_sha256,state)
                VALUES ('meeting','chunk','lzfse',1,'audio/chunk.caf.lzfse',100,10000,'bad',?,'publishing')
                """, arguments: [chunk.sha256])
        }
        store = try MeetingStore(paths: AppPaths(root: root))
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: packed.path))
        XCTAssertTrue(try store.audioAssets.compact(chunk: chunk))
    }

    func testActiveReaderKeepsOriginalUntilLeaseReleases() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ECHO_TEST_ROOT"] ?? FileManager.default.currentDirectoryPath + "/tmp/tests")
            .appendingPathComponent("asset-lease-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(paths: AppPaths(root: root))
        try store.createMeeting(Meeting(id: "meeting", title: "Lease", startedAt: Date(), endedAt: Date(),
                                        state: .ready, language: "en", sourceName: "Test",
                                        usesEchoCancellation: false, transcriptRevision: 0))
        let file = try store.paths.resolveMeetingAsset(meetingID: "meeting", relativePath: "audio/lease.caf")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: 300_000).write(to: file)
        let chunk = CapturedChunk(id: "lease", meetingID: "meeting", epochID: "epoch", track: .remote,
                                  relativePath: "audio/lease.caf", startTime: 0, duration: 1,
                                  sampleRate: 48_000, frameCount: 48_000, sha256: try MeetingStore.sha256(file))
        try store.addChunk(chunk)
        var reader: AudioAssetLease? = try store.audioAssets.acquireSync(chunk: chunk)
        XCTAssertTrue(try store.audioAssets.compact(chunk: chunk))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try Data(contentsOf: reader!.url).count, 300_000)
        reader = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try Data(contentsOf: store.audioAssets.acquireSync(chunk: chunk).url).count, 300_000)
    }
}
