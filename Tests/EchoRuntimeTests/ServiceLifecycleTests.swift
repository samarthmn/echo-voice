import XCTest
import EchoCore
@testable import EchoRuntime

final class ServiceLifecycleTests: XCTestCase {
    func testCancelledServiceResponseKeepsCancellationMeaning() {
        let response = Data(#"{"error":{"code":"cancelled","message":"Cancelled","retryable":false}}"#.utf8)
        XCTAssertTrue(LocalService.responseError(response, statusCode: 409) is CancellationError)
    }
    func testWorkerEnvironmentDoesNotInheritCredentialsOrInjectedLibraries() {
        let environment = LocalService.cleanEnvironment()
        let allowed: Set<String> = ["HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "LC_CTYPE", "__CF_USER_TEXT_ENCODING", "PATH"]
        XCTAssertTrue(Set(environment.keys).isSubset(of: allowed))
        XCTAssertEqual(environment["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
    }
    func testConcurrentCallerWaitsForServiceReadiness() async throws {
        let base = ProcessInfo.processInfo.environment["ECHO_TEST_ROOT"] ?? FileManager.default.currentDirectoryPath + "/tmp/tests"
        let root = URL(fileURLWithPath: base).appendingPathComponent("service-lifecycle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        let bin = paths.runtimeURL.appendingPathComponent("venv/bin")
        let module = paths.runtimeURL.appendingPathComponent("service/echo_service")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: module, withIntermediateDirectories: true)
        // Apple's /usr/bin/python3 is a developer-tool shim. Renaming it through
        // a symlink makes it look for the nonexistent Xcode tool named "python".
        let launcher = bin.appendingPathComponent("python")
        try "#!/bin/sh\nexec /usr/bin/python3 \"$@\"\n".write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
        try Self.slowService.write(to: module.appendingPathComponent("__main__.py"), atomically: true, encoding: .utf8)
        let service = LocalService(paths: paths)
        let initial = Task { try await service.start() }
        try await Task.sleep(nanoseconds: 200_000_000)
        do {
            let health = try await service.health()
            try await initial.value
            XCTAssertEqual(health.status, "ready")
            await service.stop()
            // A stopped service can launch again; an old startup must not clear it.
            let restarted = try await service.health()
            XCTAssertEqual(restarted.status, "ready")
            await service.stop()
        } catch {
            initial.cancel(); await service.stop()
            let diagnostic = (try? String(contentsOf: root.appendingPathComponent("fixture-error.log"), encoding: .utf8)) ?? "No fixture diagnostics"
            XCTFail("Fixture service failed: \(error.localizedDescription). \(diagnostic)")
        }
    }

    private static let slowService = #"""
import os, sys
sys.stderr = open(os.path.join(os.environ["ECHO_DATA_ROOT"], "fixture-error.log"), "w")
import http.server, json, time
token = json.loads(sys.stdin.readline())["token"]
port = int(sys.argv[sys.argv.index("--port") + 1])
time.sleep(0.75)
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.headers.get("Authorization") != "Bearer " + token:
            self.send_error(401); return
        body = json.dumps({"status":"ready", "capabilities":{"transcribe":False,"prepare_audio":False,"diarize":False}, "models":{}}).encode()
        self.send_response(200); self.send_header("Content-Length",str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *_): pass
http.server.HTTPServer(("127.0.0.1", port), Handler).serve_forever()
"""#
}
