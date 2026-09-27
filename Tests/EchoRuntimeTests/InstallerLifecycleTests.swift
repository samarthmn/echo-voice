import XCTest
import Darwin
@testable import EchoRuntime

final class InstallerLifecycleTests: XCTestCase {
    private func root() throws -> URL {
        let base = ProcessInfo.processInfo.environment["ECHO_TEST_ROOT"] ?? FileManager.default.currentDirectoryPath + "/tmp/tests"
        let path = URL(fileURLWithPath: base).appendingPathComponent("installer-lifecycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }

    func testAlreadyCancelledCommandNeverLaunches() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("launched")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ManagedCommand.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "touch \"$1\"", "fixture", marker.path], environment: ["PATH": "/usr/bin:/bin"], input: nil, onProgress: { _ in })
        }
        do { _ = try await task.value; XCTFail("A cancelled command was launched") }
        catch is CancellationError { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testCancellationAtSpawnBoundaryIsLatched() throws {
        let state = CommandState()
        let input = Pipe(), output = Pipe(), error = Pipe()
        defer {
            for pipe in [input, output, error] {
                try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close()
            }
        }
        state.cancel()
        XCTAssertThrowsError(try state.launch(executable: URL(fileURLWithPath: "/bin/true"), arguments: [], environment: ["PATH": "/usr/bin:/bin"], stdin: input, stdout: output, stderr: error)) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testCancellationKillsTermIgnoringDescendantsAndReturnsCancellation() async throws {
        try await exerciseDescendantCleanup(cancel: true)
    }

    func testLeaderExitCleansDescendantsHoldingOutputPipes() async throws {
        try await exerciseDescendantCleanup(cancel: false)
    }

    func testLeaderExitKillsDescendantWithClosedOutputPipes() async throws {
        try await exerciseDescendantCleanup(cancel: false, closedOutput: true)
    }

    private func exerciseDescendantCleanup(cancel: Bool, closedOutput: Bool = false) async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let childFile = directory.appendingPathComponent("child.pid")
        let parentFile = directory.appendingPathComponent("parent.pid")
        let started = expectation(description: "Descendant started")
        let finished = expectation(description: "Managed setup completed")
        let ending = cancel ? "wait" : "exit 0"
        let redirect = closedOutput ? "exec </dev/null >/dev/null 2>&1;" : ""
        let script = """
        trap '' TERM
        echo $$ > "$1/parent.pid"
        /bin/sh -c 'trap "" TERM; echo $$ > "$1/child.pid"; echo "{\\"status\\":\\"ready\\"}"; \(redirect) exec /bin/sleep 30' fixture "$1" &
        while [ ! -s "$1/child.pid" ]; do /bin/sleep 0.01; done
        \(ending)
        """
        let task = Task {
            defer { finished.fulfill() }
            return try await ManagedCommand.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script, "fixture", directory.path], environment: ["PATH": "/usr/bin:/bin"], input: nil, onProgress: { progress in if progress.status == "ready" { started.fulfill() } })
        }
        defer {
            task.cancel()
            for file in [childFile, parentFile] {
                if let value = try? String(contentsOf: file, encoding: .utf8), let pid = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)) { _ = Darwin.kill(pid, SIGKILL) }
            }
        }
        await fulfillment(of: [started], timeout: 3)
        let childText = try String(contentsOf: childFile, encoding: .utf8)
        let childPID = try XCTUnwrap(Int32(childText.trimmingCharacters(in: .whitespacesAndNewlines)))
        if cancel { task.cancel() }
        await fulfillment(of: [finished], timeout: 3)
        for _ in 0..<50 where Darwin.kill(childPID, 0) == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNotEqual(Darwin.kill(childPID, 0), 0, "Setup left its descendant running")
        // Clean up immediately if the tested implementation failed to terminate.
        if Darwin.kill(childPID, 0) == 0 { _ = Darwin.kill(childPID, SIGKILL) }
        if let text = try? String(contentsOf: parentFile, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), Darwin.kill(pid, 0) == 0 { _ = Darwin.kill(pid, SIGKILL) }
        do {
            _ = try await task.value
            XCTAssertFalse(cancel, "Cancellation must not report setup success")
        } catch is CancellationError {
            XCTAssertTrue(cancel)
        }
    }

    func testSecretInputRemainsOnStdinAndChildGetsOnlySuppliedEnvironment() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let captured = directory.appendingPathComponent("stdin.json")
        let payload = Data("{\"token\":\"synthetic-stdin-token\"}\n".utf8)
        let script = "[ -z \"${HF_TOKEN+x}\" ] && [ \"$ECHO_FIXTURE_ALLOWED\" = yes ] || exit 5; /bin/cat > \"$1\""
        _ = try await ManagedCommand.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script, "fixture", captured.path], environment: ["PATH": "/usr/bin:/bin", "ECHO_FIXTURE_ALLOWED": "yes"], input: payload, onProgress: { _ in })
        XCTAssertEqual(try Data(contentsOf: captured), payload)
    }

    func testProgressIsDeliveredBeforeChildExits() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let acknowledged = directory.appendingPathComponent("progress-received")
        // The child can succeed only if its small, split progress line reaches
        // the callback before EOF. A buffered reader makes this fixture fail.
        let script = """
        printf '{"sta'
        /bin/sleep 0.02
        printf 'tus":"ready"}\\n'
        attempts=0
        while [ ! -f "$1" ]; do
            attempts=$((attempts + 1))
            [ "$attempts" -lt 100 ] || exit 7
            /bin/sleep 0.02
        done
        """
        _ = try await ManagedCommand.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script, "fixture", acknowledged.path], environment: ["PATH": "/usr/bin:/bin"], input: nil, onProgress: { progress in
            if progress.status == "ready" { try? Data().write(to: acknowledged) }
        })
        XCTAssertTrue(FileManager.default.fileExists(atPath: acknowledged.path))
    }

    func testStructuredProgressCarriesByteCounts() throws {
        let line = Data(#"{"stage":"download","model":"parakeet","completed_bytes":250,"total_bytes":1000,"status":"Downloading"}"#.utf8)
        let progress = try XCTUnwrap(SetupProgress(line: line))
        XCTAssertEqual(progress.stage, "download")
        XCTAssertEqual(progress.model, "parakeet")
        XCTAssertEqual(progress.completedBytes, 250)
        XCTAssertEqual(progress.totalBytes, 1000)
        XCTAssertEqual(progress.fraction ?? -1, 0.25, accuracy: 0.0001)
        XCTAssertEqual(SetupProgress(line: Data(#"{"stage":"model","model":"asr","status":"checking"}"#.utf8))?.message, "Checking downloaded files…")
        XCTAssertNil(SetupProgress(line: Data(#"{"stage":"download","bytes":10}"#.utf8)), "Lines without a status are not user-facing")
        XCTAssertNil(SetupProgress(line: Data("not json".utf8)))
    }
}
