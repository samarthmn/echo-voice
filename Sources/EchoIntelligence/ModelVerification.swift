import Foundation
import CryptoKit
import Darwin

/// Verifies native MLX inputs against the manifest bundled with the application.
/// The installation receipt never supplies trusted hashes. Call off the main actor.
public final class ModelVerifier: @unchecked Sendable {
    private struct Manifest: Decodable { let models: [String: Model] }
    private struct Model: Decodable { let revision: String; let files: [PinnedFile] }
    private struct PinnedFile: Decodable {
        let path: String
        let size: Int64
        let sha256: String?
        let git_blob_sha1: String?
    }
    private struct Receipt: Decodable { let revision: String }
    private struct Metadata: Equatable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64
        init(_ value: stat) {
            device = value.st_dev; inode = value.st_ino; size = value.st_size
            modifiedSeconds = Int64(value.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
            changedSeconds = Int64(value.st_ctimespec.tv_sec)
            changedNanoseconds = Int64(value.st_ctimespec.tv_nsec)
        }
    }
    private enum VerificationError: Error { case invalid }
    private let manifest: Manifest?
    private let lock = NSLock()
    private var verifiedFiles: [String: Metadata] = [:]

    /// Supply the app's immutable `service/models.json`, never an installed model receipt.
    public init(manifestURL: URL) {
        manifest = try? JSONDecoder().decode(Manifest.self, from: Self.smallFile(manifestURL))
    }

    /// `expectedRevision` binds verification to a caller that constructs its own pinned load path.
    /// Returns false for cancellation, missing assets, malformed metadata, or an integrity failure.
    public func verify(name: String, modelsURL: URL, expectedRevision: String? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        do {
            try Task.checkCancellation()
            guard ["notes", "gemma", "gptoss"].contains(name), modelsURL.isFileURL,
                  let model = manifest?.models[name], Self.isHex(model.revision, count: 40),
                  expectedRevision == nil || expectedRevision == model.revision,
                  !model.files.isEmpty else { return false }
            let listed = Set(model.files.map(\.path))
            guard listed.count == model.files.count, listed.contains("config.json"),
                  listed.contains("tokenizer.json"), listed.contains(where: { $0.hasSuffix(".safetensors") }),
                  model.files.allSatisfy({ file in
                      Self.safeRelativePath(file.path) && file.path != ".verified.json" && file.size >= 0 &&
                      ((file.sha256.map { Self.isHex($0, count: 64) } ?? false) ||
                       (file.sha256 == nil && (file.git_blob_sha1.map { Self.isHex($0, count: 40) } ?? false)))
                  }) else { return false }
            let directory = modelsURL.appendingPathComponent(name, isDirectory: true)
                .appendingPathComponent(model.revision, isDirectory: true)
            let directoryInfo = try Self.inspectPath(directory)
            guard directoryInfo.st_mode & S_IFMT == S_IFDIR else { return false }
            let receiptURL = directory.appendingPathComponent(".verified.json")
            let receipt = try JSONDecoder().decode(Receipt.self, from: Self.smallFile(receiptURL))
            guard receipt.revision == model.revision else { return false }

            // MLX recursively loads every safetensors file, not just the index's entries.
            // Reject all unlisted files so tokenizer/config fallbacks cannot bypass the pins either.
            var enumerationFailed = false
            guard let iterator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil,
                errorHandler: { _, _ in enumerationFailed = true; return false }) else { return false }
            let prefix = directory.path + "/"
            for case let item as URL in iterator {
                try Task.checkCancellation()
                let info = try Self.inspectPath(item)
                if info.st_mode & S_IFMT == S_IFDIR { continue }
                guard info.st_mode & S_IFMT == S_IFREG, item.path.hasPrefix(prefix) else { return false }
                let relative = String(item.path.dropFirst(prefix.count))
                guard listed.contains(relative) || relative == ".verified.json" else { return false }
            }
            guard !enumerationFailed else { return false }
            for file in model.files {
                try Task.checkCancellation()
                let url = directory.appendingPathComponent(file.path)
                let info = try Self.inspectPath(url)
                guard info.st_mode & S_IFMT == S_IFREG, info.st_size == file.size else { return false }
                let metadata = Metadata(info)
                if verifiedFiles[url.path] == metadata { continue }
                verifiedFiles.removeValue(forKey: url.path)
                guard try Self.matchesDigest(file, at: url, metadata: metadata) else { return false }
                verifiedFiles[url.path] = metadata
            }
            return true
        } catch { return false }
    }

    private static func matchesDigest(_ file: PinnedFile, at url: URL, metadata: Metadata) throws -> Bool {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw VerificationError.invalid }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, Metadata(opened) == metadata else { return false }
        var sha256 = SHA256(), gitBlob = Insecure.SHA1()
        let useSHA256 = file.sha256 != nil
        if !useSHA256 { gitBlob.update(data: Data("blob \(file.size)\0".utf8)) }
        while true {
            try Task.checkCancellation()
            guard let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty else { break }
            if useSHA256 { sha256.update(data: bytes) } else { gitBlob.update(data: bytes) }
        }
        var finished = stat()
        guard fstat(descriptor, &finished) == 0, Metadata(finished) == metadata,
              Metadata(try inspectPath(url)) == metadata else { return false }
        let actual = useSHA256 ? sha256.finalize().map { String(format: "%02x", $0) }.joined()
            : gitBlob.finalize().map { String(format: "%02x", $0) }.joined()
        return actual == (file.sha256 ?? file.git_blob_sha1)
    }

    /// lstat each component: resolving a symlink and validating its destination would trust it.
    private static func inspectPath(_ url: URL) throws -> stat {
        guard url.isFileURL else { throw VerificationError.invalid }
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        var info = stat()
        for component in url.standardizedFileURL.pathComponents.dropFirst() {
            current.appendPathComponent(component)
            guard lstat(current.path, &info) == 0, info.st_mode & S_IFMT != S_IFLNK else {
                throw VerificationError.invalid
            }
        }
        return info
    }

    private static func smallFile(_ url: URL) throws -> Data {
        let info = try inspectPath(url)
        guard info.st_mode & S_IFMT == S_IFREG, info.st_size > 0, info.st_size <= 2_097_152 else {
            throw VerificationError.invalid
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw VerificationError.invalid }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, Metadata(opened) == Metadata(info) else { throw VerificationError.invalid }
        let data = try handle.read(upToCount: 2_097_153) ?? Data()
        var finished = stat()
        guard data.count == info.st_size, fstat(descriptor, &finished) == 0,
              Metadata(finished) == Metadata(info), Metadata(try inspectPath(url)) == Metadata(info) else {
            throw VerificationError.invalid
        }
        return data
    }

    private static func safeRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.contains("\\") && !path.contains("\0") &&
        path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    private static func isHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
