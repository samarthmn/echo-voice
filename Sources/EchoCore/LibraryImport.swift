import Foundation
import GRDB

/// Copies only the durable library. Never imports executable runtimes, credentials, or models.
/// Publication occurs before opening the destination database on the next launch.
public enum LibraryImport {
    private struct Journal: Codable {
        var id: String
        var activating: Bool
        var previous: [String]
    }
    private static let components = ["echo.sqlite", "echo.sqlite-wal", "echo.sqlite-shm", "meetings", "Deleted Meetings"]
    private static func journalURL(_ paths: AppPaths) -> URL { paths.root.appendingPathComponent(".library-import.json") }
    public static func hasPending(destination: AppPaths) -> Bool { FileManager.default.fileExists(atPath: journalURL(destination).path) }
    private static func readOnly(_ url: URL) throws -> DatabaseQueue {
        var configuration = Configuration(); configuration.readonly = true
        return try DatabaseQueue(path: url.path, configuration: configuration)
    }
    private static func requireEmpty(_ paths: AppPaths) throws {
        guard FileManager.default.fileExists(atPath: paths.databaseURL.path) else { return }
        let database = try readOnly(paths.databaseURL)
        guard try database.read({ try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM meetings") ?? 0 }) == 0 else {
            throw EchoCoreError.invalidValue("Import requires an empty destination library. Your existing meetings have not been changed.")
        }
    }
    private static func rejectLinks(_ root: URL) throws {
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]
        let values = try root.resourceValues(forKeys: keys)
        guard values.isSymbolicLink != true else { throw EchoCoreError.invalidValue("Library contains a symbolic link") }
        if values.isDirectory == true {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys)) else { throw EchoCoreError.invalidValue("Cannot read library") }
            for case let item as URL in enumerator {
                let value = try item.resourceValues(forKeys: keys)
                guard value.isSymbolicLink != true, value.isRegularFile == true || value.isDirectory == true else { throw EchoCoreError.invalidValue("Library contains a link or unsupported file") }
            }
        }
    }
    public static func stage(source: URL, destination: AppPaths) throws { try stage(source: source, destination: destination, checkpoint: { _ in }) }
    static func stage(source: URL, destination: AppPaths, checkpoint: (String) throws -> Void) throws {
        let manager = FileManager.default
        let sourcePath = source.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let destinationPath = destination.root.resolvingSymlinksInPath().path + "/"
        guard !sourcePath.hasPrefix(destinationPath), !destinationPath.hasPrefix(sourcePath), !hasPending(destination: destination) else { throw EchoCoreError.invalidValue("An import is already pending or the libraries overlap") }
        try requireEmpty(destination)
        let sourcePaths = AppPaths(root: source)
        try rejectLinks(sourcePaths.databaseURL); try rejectLinks(sourcePaths.meetingsURL)
        let id = UUID().uuidString
        let staging = destination.root.appendingPathComponent(".import-" + id)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        do {
            let sourceDB = try readOnly(sourcePaths.databaseURL)
            guard try sourceDB.read({ try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM meetings WHERE state IN ('recording','paused')") ?? 0 }) == 0 else { throw EchoCoreError.invalidValue("Close the source app after stopping its recording before importing") }
            let destinationDB = try DatabaseQueue(path: staging.appendingPathComponent("echo.sqlite").path)
            try sourceDB.backup(to: destinationDB)
            try destinationDB.close()
            try manager.copyItem(at: sourcePaths.meetingsURL, to: staging.appendingPathComponent("meetings"))
            let deleted = source.appendingPathComponent("Deleted Meetings")
            if manager.fileExists(atPath: deleted.path) { try rejectLinks(deleted); try manager.copyItem(at: deleted, to: staging.appendingPathComponent("Deleted Meetings")) }
            let imported = try MeetingStore(paths: AppPaths(root: staging))
            try imported.database.read { db in
                guard try String.fetchOne(db, sql: "PRAGMA integrity_check") == "ok", try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty else { throw EchoCoreError.invalidValue("Library database failed validation") }
            }
            for meeting in try imported.meetings() {
                for chunk in try imported.chunks(meetingID: meeting.id) {
                    let lease = try imported.audioAssets.acquireSync(chunk: chunk)
                    let file = lease.url
                    guard try MeetingStore.sha256(file) == chunk.sha256 else { throw EchoCoreError.checksumMismatch(chunk.relativePath) }
                }
            }
            try imported.database.close()
            let journal = Journal(id: id, activating: false, previous: components.filter { manager.fileExists(atPath: destination.root.appendingPathComponent($0).path) })
            try JSONEncoder().encode(journal).write(to: journalURL(destination), options: .atomic)
            try checkpoint("journal-published")
            try MeetingStore.syncDirectory(destination.root)
        } catch {
            // Once published, the journal owns staging even if its durability barrier fails.
            if !hasPending(destination: destination) { try? manager.removeItem(at: staging) }
            throw error
        }
    }
    public static func activatePending(destination: AppPaths) throws { try activatePending(destination: destination, checkpoint: { _ in }) }
    static func activatePending(destination: AppPaths, checkpoint: (String) throws -> Void) throws {
        guard hasPending(destination: destination) else { return }
        let manager = FileManager.default
        var journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalURL(destination)))
        guard UUID(uuidString: journal.id) != nil, journal.previous.allSatisfy(components.contains) else { throw EchoCoreError.invalidValue("Invalid library import journal") }
        let staging = destination.root.appendingPathComponent(".import-" + journal.id)
        try rejectLinks(staging)
        let previous = staging.appendingPathComponent("previous")
        if !journal.activating {
            try requireEmpty(destination)
            try manager.createDirectory(at: previous, withIntermediateDirectories: true)
            journal.activating = true
            try JSONEncoder().encode(journal).write(to: journalURL(destination), options: .atomic)
            try MeetingStore.syncDirectory(destination.root)
        }
        for name in journal.previous where !manager.fileExists(atPath: previous.appendingPathComponent(name).path) {
            try manager.moveItem(at: destination.root.appendingPathComponent(name), to: previous.appendingPathComponent(name))
        }
        try checkpoint("old-moved")
        for name in ["echo.sqlite", "meetings", "Deleted Meetings"] {
            let staged = staging.appendingPathComponent(name)
            if manager.fileExists(atPath: staged.path) { try manager.moveItem(at: staged, to: destination.root.appendingPathComponent(name)) }
        }
        try MeetingStore.syncDirectory(destination.root)
        try checkpoint("new-moved")
        try manager.removeItem(at: journalURL(destination))
        // Old destination was empty; models/runtime were never moved. Source remains untouched.
        try? manager.removeItem(at: staging)
    }
}
