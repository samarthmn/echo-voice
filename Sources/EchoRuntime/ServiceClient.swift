import Foundation
import Darwin
import EchoCore

public struct ServiceHealth: Decodable, Sendable {
    public struct Capability: Decodable, Sendable {
        public var transcribe: Bool
        public var prepare_audio: Bool
        public var diarize: Bool
    }
    public struct Model: Decodable, Sendable { public var ready: Bool; public var revision: String }
    public var status: String
    public var capabilities: Capability
    public var models: [String: Model]
    public var speech_models: [String: Bool]?
    public func canTranscribe(_ model: SpeechRecognitionModel) -> Bool {
        speech_models?[model.rawValue] ?? false
    }
}

public struct SpeechResult: Decodable, Sendable {
    public struct Word: Decodable, Sendable {
        public var text: String; public var location: Int; public var length: Int
        public var start: Double; public var end: Double?; public var source: TimingSource
        public var derived: Bool; public var probability: Double?
    }
    public struct Correction: Decodable, Sendable { public var entry_id: String }
    public struct Segment: Decodable, Sendable {
        public var start: Double; public var end: Double; public var text: String
        public var words: [Word]?; public var original_text: String?; public var uncertain: Bool?
        public var corrections: [Correction]?; public var confidence: [String: Double]?
    }
    public var segments: [Segment]
}

public struct DiarizationResult: Decodable, Sendable {
    public struct Turn: Decodable, Sendable { public var start: Double; public var end: Double; public var speaker: String }
    public var turns: [Turn]
    public var partial: Bool
}

public struct PrepareAudioResult: Decodable, Sendable {
    public var sample_rate: Double
    public var frame_count: Int64
    public var relative_path: String
}

public enum RuntimeError: LocalizedError {
    case setupNeeded, service(String), invalidResponse, processFailed(String)
    public var errorDescription: String? {
        switch self {
        case .setupNeeded: return "Install the local runtime in Settings first."
        case .service(let message), .processFailed(let message): return message
        case .invalidResponse: return "The local speech service returned an unreadable response. Try restarting it in Settings."
        }
    }
}

public protocol MeetingAudioService: Sendable {
    func health() async throws -> ServiceHealth
    func transcribe(_ body: [String: Any]) async throws -> SpeechResult
    func prepareAudio(_ body: [String: Any]) async throws -> PrepareAudioResult
    func diarize(_ body: [String: Any]) async throws -> DiarizationResult
    func cancel(jobID: String) async
    func unload() async
}

public actor LocalService: MeetingAudioService {
    private struct ServiceErrorEnvelope: Decodable {
        struct Detail: Decodable {
            let code: String
            let message: String
            let retryable: Bool
        }
        let error: Detail
    }

    static func responseError(_ data: Data, statusCode: Int) -> Error {
        guard let detail = try? JSONDecoder().decode(ServiceErrorEnvelope.self, from: data).error else {
            return RuntimeError.service("Local processing failed (\(statusCode)). Your saved audio is safe.")
        }
        if detail.code == "cancelled" { return CancellationError() }
        return RuntimeError.service(detail.message)
    }

    private let paths: AppPaths
    private var process: Process?
    private var port = 0
    private var token = ""
    private var startupTask: Task<Void, Error>?
    private var startupID: UUID?
    private var shutdownTask: Task<Void, Never>?
    private let session: URLSession

    public init(paths: AppPaths) {
        self.paths = paths
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3600
        config.timeoutIntervalForResource = 24 * 3600
        config.connectionProxyDictionary = [:]
        session = URLSession(configuration: config)
    }

    public var installed: Bool {
        FileManager.default.isExecutableFile(atPath: RuntimeLayout(paths: paths).python.path)
    }

    public func start() async throws {
        guard shutdownTask == nil else { throw CancellationError() }
        if let startupTask { return try await startupTask.value }
        if process?.isRunning == true { return }
        let id = UUID()
        let task = Task { try await self.launch() }
        startupTask = task; startupID = id
        defer { if startupID == id { startupTask = nil; startupID = nil } }
        try await task.value
    }

    private func launch() async throws {
        guard installed else { throw RuntimeError.setupNeeded }
        port = try Self.availablePort()
        token = UUID().uuidString + UUID().uuidString
        let child = Process()
        let runtime = RuntimeLayout(paths: paths)
        child.executableURL = runtime.python
        child.arguments = ["-m", "echo_service", "serve", "--port", String(port)]
        let bundledService = ModelCatalog.bundledURL.deletingLastPathComponent()
        let serviceCode = FileManager.default.fileExists(atPath: bundledService.appendingPathComponent("echo_service").path) ? bundledService : paths.runtimeURL.appendingPathComponent("service")
        child.currentDirectoryURL = serviceCode
        var env = Self.cleanEnvironment()
        env.merge(runtime.environment()) { _, new in new }
        env["ECHO_DATA_ROOT"] = paths.root.path
        env["ECHO_PARENT_PID"] = String(getpid())
        env["PYTHONPATH"] = serviceCode.path + ":" + runtime.voiceStudio.path
        env["HF_HUB_OFFLINE"] = "1"; env["TRANSFORMERS_OFFLINE"] = "1"; env["HF_HUB_DISABLE_TELEMETRY"] = "1"
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        let temporary = paths.runtimeURL.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        env["TMPDIR"] = temporary.path
        child.environment = env
        let input = Pipe(), output = Pipe(), errors = Pipe()
        child.standardInput = input; child.standardOutput = output; child.standardError = errors
        output.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        errors.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        child.terminationHandler = { _ in
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
        }
        try child.run()
        process = child
        try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: ["token": token]))
        try input.fileHandleForWriting.write(contentsOf: Data([10]))
        try input.fileHandleForWriting.close()
        do {
            for _ in 0..<150 {
                try Task.checkCancellation()
                guard child.isRunning else { throw RuntimeError.service(runtime.bundled ? "The included speech service could not start. Reinstall Echo Voice to restore its runtime." : "The local speech service could not start. Repair the runtime in Settings.") }
                if (try? await requestRaw("health", method: "GET", body: nil, timeout: 1)) != nil { return }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            throw RuntimeError.service("The local speech service did not become ready. Restart it in Settings.")
        } catch { if child.isRunning { child.terminate() }; if process === child { process = nil }; throw error }
    }

    public func health() async throws -> ServiceHealth {
        try await start()
        return try JSONDecoder().decode(ServiceHealth.self, from: await requestRaw("health", method: "GET", body: nil, timeout: 5))
    }

    public func transcribe(_ body: [String: Any]) async throws -> SpeechResult {
        try await start()
        return try JSONDecoder().decode(SpeechResult.self, from: await requestRaw("transcribe", body: body))
    }

    public func prepareAudio(_ body: [String: Any]) async throws -> PrepareAudioResult {
        try await start()
        return try JSONDecoder().decode(PrepareAudioResult.self, from: await requestRaw("prepare-audio", body: body))
    }

    public func diarize(_ body: [String: Any]) async throws -> DiarizationResult {
        try await start()
        return try JSONDecoder().decode(DiarizationResult.self, from: await requestRaw("diarize", body: body, timeout: 6 * 3600))
    }

    public func cancel(jobID: String) async { _ = try? await requestRaw("cancel", body: ["job_id": jobID], timeout: 5) }
    public func unload() async { if process?.isRunning == true { _ = try? await requestRaw("unload", body: [:], timeout: 10) } }
    public func stop() async {
        if let shutdownTask { await shutdownTask.value; return }
        let task = Task { await self.finishShutdown() }
        shutdownTask = task
        await task.value
        shutdownTask = nil
    }

    private func finishShutdown() async {
        let child = process, startup = startupTask
        startup?.cancel()
        if child?.isRunning == true { child?.terminate() }
        _ = try? await startup?.value
        if let child {
            // Let the service close workers before a repair replaces its environment.
            await Task.detached {
                for _ in 0..<50 {
                    if !child.isRunning { return }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            }.value
        }
        process = nil; startupTask = nil; startupID = nil
    }

    private func requestRaw(_ endpoint: String, method: String = "POST", body: [String: Any]?, timeout: TimeInterval = 3600) async throws -> Data {
        guard let url = URL(string: "http://127.0.0.1:\(port)/echo/v1/\(endpoint)") else { throw RuntimeError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method; request.timeoutInterval = timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw RuntimeError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            throw Self.responseError(data, statusCode: response.statusCode)
        }
        return data
    }

    private static func availablePort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw RuntimeError.service("Could not reserve a local service port.") }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard result == 0 else { throw RuntimeError.service("Could not reserve a local service port.") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) } }
        guard nameResult == 0 else { throw RuntimeError.service("Could not determine local service port.") }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    /// Start from a small allowlist: shell credentials, proxy settings, and injected
    /// development libraries must not enter the managed inference process.
    static func cleanEnvironment() -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        let keys = ["HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "LC_CTYPE", "__CF_USER_TEXT_ENCODING"]
        var result = Dictionary(uniqueKeysWithValues: keys.compactMap { key in inherited[key].map { (key, $0) } })
        result["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        return result
    }
}
