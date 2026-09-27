import XCTest
@testable import EchoCore

final class LibraryRecoveryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        let base: URL
        if let configured = ProcessInfo.processInfo.environment["ECHO_TEST_ROOT"] {
            base = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            base = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("tmp/core-tests", isDirectory: true)
        }
        root = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testUnreadableDatabaseStaysInPlaceAndExplainsRecovery() throws {
        let paths = AppPaths(root: root)
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try Data("not a sqlite database".utf8).write(to: paths.databaseURL)
        XCTAssertThrowsError(try MeetingStore(paths: paths))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.databaseURL.path))
        let message = LibraryRecovery.message(root: paths.root, reason: "database is unreadable")
        XCTAssertTrue(message.contains(paths.root.path))
        XCTAssertTrue(message.contains("Nothing was deleted"))
        XCTAssertTrue(message.contains("move that folder aside"))
        XCTAssertTrue(message.contains("database is unreadable"))
    }

    func testInvalidImportJournalDoesNotRemoveExistingFiles() throws {
        let paths = AppPaths(root: root)
        _ = try MeetingStore(paths: paths)
        let journal = paths.root.appendingPathComponent(".library-import.json")
        try Data("[]".utf8).write(to: journal)
        XCTAssertThrowsError(try LibraryImport.activatePending(destination: paths))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.databaseURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))
    }
}
