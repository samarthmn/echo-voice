import Foundation
import XCTest

final class LibraryLaunchUITests: XCTestCase {
    func testLibraryShellOpensWithAnIsolatedEmptyLibrary() throws {
        let testRoot = try XCTUnwrap(ProcessInfo.processInfo.environment["ECHO_TEST_ROOT"])
        let library = URL(fileURLWithPath: testRoot, isDirectory: true)
            .appendingPathComponent("ui-launch-\(UUID().uuidString)", isDirectory: true)
        let app = XCUIApplication()
        app.launchEnvironment["ECHO_DATA_ROOT"] = library.path
        defer {
            app.terminate()
            try? FileManager.default.removeItem(at: library)
        }

        app.launch()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    }
}
