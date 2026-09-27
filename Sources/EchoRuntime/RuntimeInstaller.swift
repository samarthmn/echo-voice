import Foundation
import Darwin
import EchoCore

/// One structured line from local setup. Byte counts cover a single catalog asset;
/// callers aggregate dependencies themselves.
public struct SetupProgress: Sendable, Equatable {
    public var stage: String?
    public var model: String?
    public var status: String
    public var completedBytes: Int64?
    public var totalBytes: Int64?
    public init(stage: String? = nil, model: String? = nil, status: String, completedBytes: Int64? = nil, totalBytes: Int64? = nil) {
        self.stage = stage; self.model = model; self.status = status; self.completedBytes = completedBytes; self.totalBytes = totalBytes
    }
    init?(line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let status = object["status"] as? String else { return nil }
        func bytes(_ key: String) -> Int64? { (object[key] as? NSNumber).map { $0.int64Value } }
        self.init(stage: object["stage"] as? String, model: object["model"] as? String, status: status, completedBytes: bytes("completed_bytes"), totalBytes: bytes("total_bytes"))
    }
    public var fraction: Double? {
        guard let completedBytes, let totalBytes, totalBytes > 0 else { return nil }
        return min(1, max(0, Double(completedBytes) / Double(totalBytes)))
    }
    /// Model lifecycle lines carry terse states; present them as sentences.
    public var message: String {
        guard stage == "model" else { return status }
        switch status {
        case "checking": return "Checking downloaded files…"
        case "ready": return "Already downloaded and verified."
        case "repairing": return "Repairing incomplete files…"
        default: return status
        }
    }
}

public actor RuntimeInstaller {
    private let paths: AppPaths
    public init(paths: AppPaths) { self.paths = paths }

    public func installRuntime(resources: URL, onProgress: @escaping @Sendable (SetupProgress) -> Void) async throws {
        let runtime = RuntimeLayout(paths: paths)
        if runtime.bundled {
            guard FileManager.default.isExecutableFile(atPath: runtime.python.path),
                  FileManager.default.isExecutableFile(atPath: runtime.communityPython.path) else {
                throw RuntimeError.processFailed("The bundled runtime is missing. Reinstall Echo Voice from its official download.")
            }
            onProgress(SetupProgress(status: "The runtime is included with Echo Voice. Choose a model to download."))
            return
        }
        let script = resources.appendingPathComponent("bootstrap-runtime.sh")
        let service = resources.appendingPathComponent("service")
        guard FileManager.default.fileExists(atPath: script.path), FileManager.default.fileExists(atPath: service.path) else {
            throw RuntimeError.processFailed("The application is missing its setup files. Rebuild or reinstall Echo Voice.")
        }
        _ = try await ManagedCommand.run(executable: URL(fileURLWithPath: "/bin/bash"), arguments: [script.path, paths.root.path, service.path], environment: LocalService.cleanEnvironment(), input: nil, onProgress: onProgress)
    }

    public func installModels(_ selection: String, token: String?, onProgress: @escaping @Sendable (SetupProgress) -> Void) async throws {
        guard try ModelCatalog(url: ModelCatalog.bundledURL).model(selection) != nil else { throw RuntimeError.processFailed("Choose a supported model group.") }
        var env = LocalService.cleanEnvironment()
        let runtime = RuntimeLayout(paths: paths)
        env.merge(runtime.environment()) { _, new in new }
        env["ECHO_DATA_ROOT"] = paths.root.path
        env["PYTHONPATH"] = ModelCatalog.bundledURL.deletingLastPathComponent().path + ":" + runtime.voiceStudio.path
        env["HF_HUB_DISABLE_TELEMETRY"] = "1"; env["PYTHONDONTWRITEBYTECODE"] = "1"
        for key in ["HF_HUB_OFFLINE", "TRANSFORMERS_OFFLINE", "HF_TOKEN", "HUGGING_FACE_HUB_TOKEN"] { env.removeValue(forKey: key) }
        let temp = paths.runtimeURL.appendingPathComponent("setup-tmp")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        env["TMPDIR"] = temp.path
        defer { try? FileManager.default.removeItem(at: temp) }
        let input = try JSONSerialization.data(withJSONObject: ["token": token ?? ""])
        _ = try await ManagedCommand.run(executable: runtime.python, arguments: ["-m", "echo_service", "setup", "--data-root", paths.root.path, "--models", selection], environment: env, input: input + Data([10]), onProgress: onProgress)
    }
    public func removeModel(_ selection: String) async throws {
        guard try ModelCatalog(url: ModelCatalog.bundledURL).model(selection) != nil else { throw RuntimeError.processFailed("Choose a supported model.") }
        var env = LocalService.cleanEnvironment()
        let runtime = RuntimeLayout(paths: paths)
        env.merge(runtime.environment()) { _, new in new }
        env["ECHO_DATA_ROOT"] = paths.root.path
        env["PYTHONPATH"] = ModelCatalog.bundledURL.deletingLastPathComponent().path
        _ = try await ManagedCommand.run(executable: runtime.python, arguments: ["-m", "echo_service", "remove-model", "--data-root", paths.root.path, "--model", selection], environment: env, input: nil, onProgress: { _ in })
    }

}

// Own the cancellation latch and process group behind one launch boundary.
// Foundation.Process cannot request POSIX_SPAWN_SETPGROUP atomically with spawn.
final class CommandState: @unchecked Sendable {
    private let lock = NSLock()
    private var processGroup: pid_t = 0
    private var cancelled = false
    private var escalation: DispatchWorkItem?
    private var output = Data()
    private var error = Data()

    func append(_ data: Data, isError: Bool) {
        lock.lock(); defer { lock.unlock() }
        if isError { error.append(data); if error.count > 32_768 { error = error.suffix(32_768) } }
        else { output.append(data); if output.count > 32_768 { output = output.suffix(32_768) } }
    }

    func launch(executable: URL, arguments: [String], environment: [String: String], stdin: Pipe, stdout: Pipe, stderr: Pipe) throws -> pid_t {
        lock.lock(); defer { lock.unlock() }
        // Cancellation between Task.checkCancellation and spawn cannot be lost.
        guard !cancelled else { throw CancellationError() }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        var code = posix_spawn_file_actions_init(&actions)
        guard code == 0 else { throw launchError(code) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        code = posix_spawnattr_init(&attributes)
        guard code == 0 else { throw launchError(code) }
        defer { posix_spawnattr_destroy(&attributes) }
        func check(_ result: Int32) throws { if result != 0 { throw launchError(result) } }
        try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)))
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        let redirects = [(stdin.fileHandleForReading.fileDescriptor, STDIN_FILENO),
                         (stdout.fileHandleForWriting.fileDescriptor, STDOUT_FILENO),
                         (stderr.fileHandleForWriting.fileDescriptor, STDERR_FILENO)]
        for (source, destination) in redirects {
            try check(posix_spawn_file_actions_adddup2(&actions, source, destination))
        }
        for pipe in [stdin, stdout, stderr] {
            for handle in [pipe.fileHandleForReading, pipe.fileHandleForWriting] where handle.fileDescriptor > STDERR_FILENO {
                try check(posix_spawn_file_actions_addclose(&actions, handle.fileDescriptor))
            }
        }
        // A child may exit before secret stdin is written. Suppress SIGPIPE on
        // this descriptor only rather than changing the application's signals.
        guard fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else { throw launchError(errno) }
        var argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        var envp = environment.keys.sorted().map { strdup("\($0)=\(environment[$0]!)") } + [nil]
        defer { for value in argv + envp { free(value) } }
        var pid: pid_t = 0
        code = posix_spawn(&pid, executable.path, &actions, &attributes, &argv, &envp)
        guard code == 0 else { throw launchError(code) }
        processGroup = pid
        return pid
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        stopGroupLocked()
    }

    func leaderExited() {
        lock.lock(); defer { lock.unlock() }
        // A failed or completed bootstrap shell may leave download/setup children
        // holding stdout open. They must finish before setup is reported complete.
        stopGroupLocked()
    }

    private func stopGroupLocked() {
        guard processGroup > 0, escalation == nil else { return }
        _ = Darwin.kill(-processGroup, SIGTERM)
        let group = processGroup
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            guard self.processGroup == group else { return }
            _ = Darwin.kill(-group, SIGKILL)
        }
        escalation = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func waitForGroupCleanup() -> Bool {
        // EOF only proves the pipes are closed. A child with redirected output
        // can still be running, so retain escalation until the group is gone.
        let deadline = DispatchTime.now() + 2
        while true {
            lock.lock()
            if processGroup == 0 || (Darwin.kill(-processGroup, 0) == -1 && errno == ESRCH) {
                escalation?.cancel(); escalation = nil
                processGroup = 0
                lock.unlock()
                return true
            }
            if DispatchTime.now() >= deadline {
                _ = Darwin.kill(-processGroup, SIGKILL)
                lock.unlock()
                return false
            }
            lock.unlock()
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    func finish() -> (output: Data, cancelled: Bool) {
        lock.lock(); defer { lock.unlock() }
        escalation?.cancel(); escalation = nil
        processGroup = 0
        return (output, cancelled)
    }

    private func launchError(_ code: Int32) -> RuntimeError {
        RuntimeError.processFailed("Local setup could not be started (error \(code)).")
    }
}

enum ManagedCommand {
    static func run(executable: URL, arguments: [String], environment: [String: String], input: Data?, onProgress: @escaping @Sendable (SetupProgress) -> Void) async throws -> Data {
        let state = CommandState()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result: Data = try await withCheckedThrowingContinuation { continuation in
                let stdout = Pipe(), stderr = Pipe(), stdin = Pipe()
                let pid: pid_t
                do {
                    pid = try state.launch(executable: executable, arguments: arguments, environment: environment, stdin: stdin, stdout: stdout, stderr: stderr)
                } catch {
                    for pipe in [stdin, stdout, stderr] { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
                    continuation.resume(throwing: error); return
                }
                // Only the child owns these pipe ends after spawn.
                try? stdin.fileHandleForReading.close()
                try? stdout.fileHandleForWriting.close(); try? stderr.fileHandleForWriting.close()
                let readers = DispatchGroup()
                for (pipe, isError) in [(stdout, false), (stderr, true)] {
                    readers.enter()
                    DispatchQueue.global(qos: .utility).async {
                        defer { try? pipe.fileHandleForReading.close(); readers.leave() }
                        var pending = Data()
                        var buffer = [UInt8](repeating: 0, count: 8192)
                        while true {
                            // FileHandle.read(upToCount:) can wait to fill its
                            // requested count on pipes. POSIX read delivers each
                            // available chunk while the setup child is running.
                            let count = buffer.withUnsafeMutableBytes { bytes in
                                Darwin.read(pipe.fileHandleForReading.fileDescriptor, bytes.baseAddress!, bytes.count)
                            }
                            if count == -1 && errno == EINTR { continue }
                            guard count > 0 else { break }
                            let data = Data(buffer.prefix(count))
                            state.append(data, isError: isError)
                            guard !isError else { continue }
                            pending.append(data)
                            while let newline = pending.firstIndex(of: 10) {
                                let line = Data(pending[..<newline]); pending.removeSubrange(...newline)
                                if let progress = SetupProgress(line: line) { onProgress(progress) }
                            }
                            if pending.count > 32_768 { pending.removeAll(keepingCapacity: false) }
                        }
                    }
                }
                DispatchQueue.global(qos: .utility).async {
                    if let input { try? stdin.fileHandleForWriting.write(contentsOf: input) }
                    try? stdin.fileHandleForWriting.close()
                    var status: Int32 = 0
                    var waited: pid_t
                    repeat { waited = waitpid(pid, &status, 0) } while waited == -1 && errno == EINTR
                    state.leaderExited()
                    let groupStopped = state.waitForGroupCleanup()
                    let outputClosed = readers.wait(timeout: .now() + 2) == .success
                    let completed = state.finish()
                    if completed.cancelled { continuation.resume(throwing: CancellationError()); return }
                    guard groupStopped, outputClosed else {
                        continuation.resume(throwing: RuntimeError.processFailed("Local setup did not stop cleanly. Please retry.")); return
                    }
                    let exitStatus: Int32 = waited == -1 ? -1 : ((status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f))
                    if exitStatus == 0 { continuation.resume(returning: completed.output) }
                    else {
                        // Never forward arbitrary stderr or secret stdin to the UI.
                        let lines = String(data: completed.output, encoding: .utf8)?.split(separator: "\n") ?? []
                        let structured = lines.reversed().compactMap { line -> String? in
                            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
                            if let error = object["error"] as? [String: Any] { return error["message"] as? String }
                            return nil
                        }.first
                        continuation.resume(throwing: RuntimeError.processFailed(structured ?? "Local setup did not finish (exit \(exitStatus)). Check your connection and available space, then retry."))
                    }
                }
            }
            try Task.checkCancellation()
            return result
        } onCancel: { state.cancel() }
    }
}
