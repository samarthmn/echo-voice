import Foundation
import GRDB

public final class AudioAssetLease: @unchecked Sendable {
    public let url: URL
    private let store: AudioAssetStore
    private let key: String
    fileprivate init(url: URL, store: AudioAssetStore, key: String) {
        self.url = url; self.store = store; self.key = key
    }
    deinit { store.release(key: key) }
}

public struct CompactionReport: Sendable {
    public var originalBytes: Int64 = 0
    public var storedBytes: Int64 = 0
    public var verifiedAssets = 0
    public var retainedOriginals = 0
    public var failures: [String] = []
}

public final class AudioAssetStore: @unchecked Sendable {
    private struct Representation {
        var path: String
        var storedSize: Int64
        var decodedSize: Int64
        var storedChecksum: String
        var canonicalChecksum: String
        var state: String
    }

    private let paths: AppPaths
    private let database: DatabaseQueue
    private let lock = NSLock()
    private var leaseCounts: [String: Int] = [:]
    private var decodedCache: [String: URL] = [:]
    private var recentCacheKeys: [String] = []
    private var reconciledCacheMeetings: Set<String> = []

    init(paths: AppPaths, database: DatabaseQueue) {
        self.paths = paths; self.database = database
    }

    private func key(_ chunk: CapturedChunk) -> String { chunk.meetingID + "/" + chunk.id }

    private func representation(_ chunk: CapturedChunk) throws -> Representation? {
        try database.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM audio_representations WHERE meeting_id=? AND chunk_id=?",
                             arguments: [chunk.meetingID, chunk.id]).map { row in
                Representation(path: row["stored_path"], storedSize: row["stored_size"],
                               decodedSize: row["decoded_size"], storedChecksum: row["stored_sha256"],
                               canonicalChecksum: row["canonical_sha256"], state: row["state"])
            }
        }
    }

    public func acquire(chunk: CapturedChunk) async throws -> AudioAssetLease {
        try acquireSync(chunk: chunk)
    }

    /// Synchronous access is for AVAudioFile and the existing synchronous
    /// assembler/export paths. Calls never run on the capture callback.
    public func acquireSync(chunk: CapturedChunk) throws -> AudioAssetLease {
        lock.lock(); defer { lock.unlock() }
        if !reconciledCacheMeetings.contains(chunk.meetingID) {
            try reconcileDecodedCacheUnlocked(meetingID: chunk.meetingID)
            reconciledCacheMeetings.insert(chunk.meetingID)
        }
        let identity = key(chunk)
        let original = try paths.resolveMeetingAsset(meetingID: chunk.meetingID, relativePath: chunk.relativePath)
        if FileManager.default.fileExists(atPath: original.path) {
            leaseCounts[identity, default: 0] += 1
            return AudioAssetLease(url: original, store: self, key: identity)
        }
        guard let representation = try representation(chunk), representation.state == "ready",
              representation.canonicalChecksum.caseInsensitiveCompare(chunk.sha256) == .orderedSame,
              representation.decodedSize > 0, representation.decodedSize <= 64 * 1_024 * 1_024 else {
            throw EchoCoreError.assetMissing(chunk.relativePath)
        }
        if let cached = decodedCache[identity], FileManager.default.fileExists(atPath: cached.path) {
            leaseCounts[identity, default: 0] += 1
            recentCacheKeys.removeAll { $0 == identity }; recentCacheKeys.append(identity)
            return AudioAssetLease(url: cached, store: self, key: identity)
        }
        let packed = try paths.resolveMeetingAsset(meetingID: chunk.meetingID, relativePath: representation.path)
        guard try MeetingStore.sha256(packed).caseInsensitiveCompare(representation.storedChecksum) == .orderedSame else {
            throw EchoCoreError.checksumMismatch(representation.path)
        }
        let cacheDirectory = paths.meetingDirectory(chunk.meetingID).appendingPathComponent("decoded-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let decoded = cacheDirectory.appendingPathComponent(chunk.id + ".caf")
        try? FileManager.default.removeItem(at: decoded)
        let restored = try LosslessChunkCodec.decompress(packed, to: decoded, maximumBytes: representation.decodedSize)
        guard restored.bytes == representation.decodedSize,
              restored.sha256.caseInsensitiveCompare(chunk.sha256) == .orderedSame else {
            try? FileManager.default.removeItem(at: decoded)
            throw EchoCoreError.checksumMismatch(chunk.relativePath)
        }
        decodedCache[identity] = decoded
        recentCacheKeys.removeAll { $0 == identity }; recentCacheKeys.append(identity)
        leaseCounts[identity, default: 0] += 1
        evictUnlocked()
        return AudioAssetLease(url: decoded, store: self, key: identity)
    }

    fileprivate func release(key: String) {
        lock.lock(); defer { lock.unlock() }
        guard let count = leaseCounts[key] else { return }
        if count > 1 { leaseCounts[key] = count - 1 }
        else {
            leaseCounts.removeValue(forKey: key)
            let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
            if parts.count == 2,
               let path: String = try? database.read({ db in
                   try String.fetchOne(db, sql: """
                       SELECT c.relative_path FROM chunks c JOIN audio_representations r
                         ON r.meeting_id=c.meeting_id AND r.chunk_id=c.id
                       WHERE c.meeting_id=? AND c.id=? AND r.state='ready'
                       """, arguments: [parts[0], parts[1]])
               }), let original = try? paths.resolveMeetingAsset(meetingID: parts[0], relativePath: path) {
                try? FileManager.default.removeItem(at: original)
            }
        }
        evictUnlocked()
    }

    private func evictUnlocked() {
        while decodedCache.count > 3,
              let victim = recentCacheKeys.first(where: { leaseCounts[$0] == nil }) {
            if let file = decodedCache.removeValue(forKey: victim) { try? FileManager.default.removeItem(at: file) }
            recentCacheKeys.removeAll { $0 == victim }
        }
    }

    /// Run after the library shell opens and lazily before first playback.
    /// Files from prior processes are disposable; this store's active readers are protected.
    public func reconcileDecodedCache(meetingID: String) throws {
        lock.lock(); defer { lock.unlock() }
        try reconcileDecodedCacheUnlocked(meetingID: meetingID)
        reconciledCacheMeetings.insert(meetingID)
    }

    private func reconcileDecodedCacheUnlocked(meetingID: String) throws {
        let directory = try paths.resolveMeetingAsset(meetingID: meetingID, relativePath: "decoded-cache")
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let tracked = Set(decodedCache.values.map(\.standardizedFileURL))
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            guard !tracked.contains(file.standardizedFileURL) else { continue }
            try FileManager.default.removeItem(at: file)
        }
        evictUnlocked()
    }

    /// Returns true only after a compressed representation is fully verified
    /// and the original can be retired without invalidating active readers.
    public func compact(chunk: CapturedChunk) throws -> Bool {
        let original = try paths.resolveMeetingAsset(meetingID: chunk.meetingID, relativePath: chunk.relativePath)
        if let existing = try representation(chunk), existing.state == "ready" {
            let packed = try paths.resolveMeetingAsset(meetingID: chunk.meetingID, relativePath: existing.path)
            guard try MeetingStore.sha256(packed).caseInsensitiveCompare(existing.storedChecksum) == .orderedSame else {
                throw EchoCoreError.checksumMismatch(existing.path)
            }
            retireOriginalIfUnused(chunk)
            return true
        }
        guard FileManager.default.fileExists(atPath: original.path) else { throw EchoCoreError.assetMissing(chunk.relativePath) }
        guard try MeetingStore.sha256(original).caseInsensitiveCompare(chunk.sha256) == .orderedSame else {
            throw EchoCoreError.checksumMismatch(chunk.relativePath)
        }
        let decodedSize = Int64(try original.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        guard decodedSize > 0, decodedSize <= 64 * 1_024 * 1_024 else { return false }
        let storedPath = chunk.relativePath + ".lzfse"
        let packed = try paths.resolveMeetingAsset(meetingID: chunk.meetingID, relativePath: storedPath)
        let staging = try paths.resolveMeetingAsset(meetingID: chunk.meetingID, relativePath: storedPath + ".partial")
        let verified = try paths.resolveMeetingAsset(meetingID: chunk.meetingID, relativePath: storedPath + ".verify")
        defer { try? FileManager.default.removeItem(at: staging); try? FileManager.default.removeItem(at: verified) }
        try? FileManager.default.removeItem(at: staging)
        let compressed = try LosslessChunkCodec.compress(original, to: staging, maximumBytes: decodedSize + 1_024 * 1_024)
        guard compressed.bytes + 128 < Int64(Double(decodedSize) * 0.95) else { return false }
        let roundTrip = try LosslessChunkCodec.decompress(staging, to: verified, maximumBytes: decodedSize)
        guard roundTrip.bytes == decodedSize,
              roundTrip.sha256.caseInsensitiveCompare(chunk.sha256) == .orderedSame else {
            throw EchoCoreError.checksumMismatch(chunk.relativePath)
        }
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO audio_representations(meeting_id,chunk_id,codec,codec_version,stored_path,stored_size,decoded_size,stored_sha256,canonical_sha256,state)
                VALUES (?,?,'lzfse',1,?,?,?,?,?,'publishing')
                ON CONFLICT(meeting_id,chunk_id) DO UPDATE SET state='publishing'
                """, arguments: [chunk.meetingID, chunk.id, storedPath, compressed.bytes, decodedSize,
                                   compressed.sha256, chunk.sha256])
        }
        if FileManager.default.fileExists(atPath: packed.path) { try FileManager.default.removeItem(at: packed) }
        try FileManager.default.moveItem(at: staging, to: packed)
        try MeetingStore.syncDirectory(packed.deletingLastPathComponent())
        try database.write { db in
            try db.execute(sql: "UPDATE audio_representations SET state='ready' WHERE meeting_id=? AND chunk_id=?",
                           arguments: [chunk.meetingID, chunk.id])
        }
        retireOriginalIfUnused(chunk)
        return true
    }

    private func retireOriginalIfUnused(_ chunk: CapturedChunk) {
        lock.lock(); defer { lock.unlock() }
        guard leaseCounts[key(chunk)] == nil,
              let row = try? representation(chunk), row.state == "ready" else { return }
        let original = try? paths.resolveMeetingAsset(meetingID: chunk.meetingID, relativePath: chunk.relativePath)
        if let original { try? FileManager.default.removeItem(at: original) }
    }

    public func storedSize(chunk: CapturedChunk) throws -> Int64 {
        if let representation = try representation(chunk), representation.state == "ready" { return representation.storedSize }
        let original = try paths.resolveMeetingAsset(meetingID: chunk.meetingID, relativePath: chunk.relativePath)
        return Int64(try original.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    }

    public func decodedSize(chunk: CapturedChunk) throws -> Int64 {
        if let representation = try representation(chunk) { return representation.decodedSize }
        return try storedSize(chunk: chunk)
    }

    /// Every managed on-disk representation of a retained chunk. Cleanup must
    /// use this inventory instead of assuming the canonical path still exists.
    public func managedPaths(chunk: CapturedChunk) throws -> Set<String> {
        var paths: Set<String> = [chunk.relativePath,
                                  chunk.relativePath + ".lzfse",
                                  chunk.relativePath + ".lzfse.partial",
                                  chunk.relativePath + ".lzfse.verify"]
        if let representation = try representation(chunk) { paths.insert(representation.path) }
        return paths
    }

    public func purgeDeleted(chunk: CapturedChunk) throws {
        lock.lock(); defer { lock.unlock() }
        let identity = key(chunk)
        guard leaseCounts[identity] == nil else {
            throw EchoCoreError.invalidValue("audio is still in use; finish playback or export before deletion completes")
        }
        let cached = decodedCache.removeValue(forKey: identity)
        recentCacheKeys.removeAll { $0 == identity }
        let persistentCache = try paths.resolveMeetingAsset(meetingID: chunk.meetingID,
                                                            relativePath: "decoded-cache/\(chunk.id).caf")
        var changedDirectories = Set<URL>()
        for file in Set([persistentCache, cached].compactMap { $0 }) where FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
            changedDirectories.insert(file.deletingLastPathComponent())
        }
        for path in [chunk.relativePath, chunk.relativePath + ".lzfse",
                     chunk.relativePath + ".lzfse.partial", chunk.relativePath + ".lzfse.verify",
                     chunk.relativePath + ".chunk.json", chunk.relativePath + ".intent.json"] {
            let file = try paths.resolveMeetingAsset(meetingID: chunk.meetingID, relativePath: path)
            if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
                changedDirectories.insert(file.deletingLastPathComponent())
            }
        }
        for directory in changedDirectories { try MeetingStore.syncDirectory(directory) }
    }

    /// An interrupted publication always leaves the canonical original in
    /// place. Clear its incomplete row so the background compactor can retry.
    func recoverPublications(onlyMeetingID: String? = nil) throws {
        let rows: [(String, String, String, String)] = try database.read { db in
            let sql = "SELECT meeting_id,chunk_id,stored_path,state FROM audio_representations WHERE state='publishing'" +
                (onlyMeetingID == nil ? "" : " AND meeting_id=?")
            return try Row.fetchAll(db, sql: sql, arguments: onlyMeetingID.map { StatementArguments([$0]) } ?? StatementArguments())
                .map { ($0["meeting_id"], $0["chunk_id"], $0["stored_path"], $0["state"]) }
        }
        for (meetingID, chunkID, storedPath, _) in rows {
            let originalPath: String? = try database.read { db in
                try String.fetchOne(db, sql: "SELECT relative_path FROM chunks WHERE meeting_id=? AND id=?",
                                    arguments: [meetingID, chunkID])
            }
            guard let originalPath,
                  let original = try? paths.resolveMeetingAsset(meetingID: meetingID, relativePath: originalPath),
                  FileManager.default.fileExists(atPath: original.path) else { continue }
            if let packed = try? paths.resolveMeetingAsset(meetingID: meetingID, relativePath: storedPath) {
                try? FileManager.default.removeItem(at: packed)
                try? FileManager.default.removeItem(at: packed.appendingPathExtension("partial"))
            }
            try database.write { db in
                try db.execute(sql: "DELETE FROM audio_representations WHERE meeting_id=? AND chunk_id=? AND state='publishing'",
                               arguments: [meetingID, chunkID])
            }
        }
    }
}

public struct AudioCompactor: Sendable {
    public let store: MeetingStore
    public init(store: MeetingStore) { self.store = store }

    public func compact(meetingID: String) async throws -> CompactionReport {
        try store.requireDeletionRecovered(meetingID: meetingID)
        guard let meeting = try store.meeting(id: meetingID),
              ![.recording, .paused, .interrupted].contains(meeting.state) else {
            throw EchoCoreError.meetingNotFound(meetingID)
        }
        var report = CompactionReport()
        for chunk in try store.chunks(meetingID: meetingID) {
            try Task.checkCancellation()
            try store.requireDeletionRecovered(meetingID: meetingID)
            let source = try store.paths.resolveMeetingAsset(meetingID: meetingID, relativePath: chunk.relativePath)
            let before = try store.audioAssets.decodedSize(chunk: chunk)
            report.originalBytes += before
            do {
                if FileManager.default.fileExists(atPath: source.path) {
                    let available = try store.paths.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
                    guard available > before * 2 + 1_000_000_000 else {
                        report.retainedOriginals += 1
                        report.storedBytes += before
                        continue
                    }
                }
                if try store.audioAssets.compact(chunk: chunk) { report.verifiedAssets += 1 }
                else { report.retainedOriginals += 1 }
                report.storedBytes += try store.audioAssets.storedSize(chunk: chunk)
            } catch {
                report.failures.append("\(chunk.id): \(error.localizedDescription)")
                report.storedBytes += before
            }
        }
        return report
    }
}
