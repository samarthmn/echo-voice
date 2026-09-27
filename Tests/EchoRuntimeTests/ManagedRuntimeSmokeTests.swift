import XCTest
import EchoCore
@testable import EchoRuntime

final class ManagedRuntimeSmokeTests: XCTestCase {
    func testProvisionedManagedRuntimeSupportsConcurrentHealthAndRestart() async throws {
        let root = try provisionedRoot()
        let paths = AppPaths(root: root)
        let meetingsBefore = try relativeEntries(at: paths.meetingsURL)
        let modelsBefore = try relativeEntries(at: paths.modelsURL)
        let service = LocalService(paths: paths)

        let installed = await service.installed
        XCTAssertTrue(installed, "ECHO_RUNTIME_TEST_ROOT must contain runtime/venv/bin/python")
        guard installed else { return }

        do {
            let healthResponses = try await withThrowingTaskGroup(of: ServiceHealth.self, returning: [ServiceHealth].self) { group in
                for _ in 0..<8 {
                    group.addTask { try await service.health() }
                }
                var responses: [ServiceHealth] = []
                for try await response in group { responses.append(response) }
                return responses
            }

            XCTAssertEqual(healthResponses.count, 8)
            for health in healthResponses { assertSetupNeededHealth(health) }

            await service.stop()
            try await service.start()
            let restartedHealth = try await service.health()
            assertSetupNeededHealth(restartedHealth)
            await service.stop()
        } catch {
            await service.stop()
            throw error
        }

        XCTAssertEqual(try relativeEntries(at: paths.meetingsURL), meetingsBefore, "Health checks must not create meeting data")
        XCTAssertEqual(try relativeEntries(at: paths.modelsURL), modelsBefore, "Health checks must not download or modify models")
    }

    private func provisionedRoot() throws -> URL {
        guard let value = ProcessInfo.processInfo.environment["ECHO_RUNTIME_TEST_ROOT"], !value.isEmpty else {
            throw XCTSkip("Set ECHO_RUNTIME_TEST_ROOT to an explicitly provisioned project-tmp runtime to run the managed service smoke test.")
        }
        let root = URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            XCTFail("ECHO_RUNTIME_TEST_ROOT does not exist or is not a directory: \(root.path)")
            throw CocoaError(.fileNoSuchFile)
        }
        return root
    }

    private func assertSetupNeededHealth(_ health: ServiceHealth, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(health.status, "ready", file: file, line: line)
        XCTAssertTrue(health.capabilities.prepare_audio, file: file, line: line)
        XCTAssertFalse(health.capabilities.transcribe, file: file, line: line)
        XCTAssertFalse(health.capabilities.diarize, file: file, line: line)

        let expectedModels: Set<String> = ["asr", "notes", "vision", "diarization", "segmentation", "embedding"]
        XCTAssertEqual(Set(health.models.keys), expectedModels, file: file, line: line)
        for model in expectedModels {
            XCTAssertEqual(health.models[model]?.ready, false, "\(model) should report setup needed", file: file, line: line)
            XCTAssertFalse(health.models[model]?.revision.isEmpty ?? true, "\(model) should retain its pinned revision", file: file, line: line)
        }
    }

    private func relativeEntries(at directory: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw CocoaError(.fileReadUnknown)
        }
        return enumerator.compactMap { item in
            guard let url = item as? URL else { return nil }
            return String(url.path.dropFirst(directory.path.count + 1))
        }.sorted()
    }
}
