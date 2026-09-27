import Foundation
import EchoCore

public struct OllamaModel: Codable, Sendable, Identifiable, Equatable {
    public var name: String
    public var digest: String
    public var size: Int64
    public var id: String { name }
    public init(name: String, digest: String, size: Int64) {
        self.name = name; self.digest = digest; self.size = size
    }
}

public enum OllamaNotesError: LocalizedError {
    case unavailable, invalidResponse, modelMissing(String), modelChanged(String), unsupportedModel(String)
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "Ollama is not running on this Mac. Start Ollama and retry meeting notes."
        case .invalidResponse: return "Ollama returned an invalid response. Retry notes or choose another local model."
        case .modelMissing(let name): return "The Ollama model “\(name)” is no longer installed. Install it in Ollama or choose another notes model."
        case .modelChanged(let name): return "The Ollama model “\(name)” changed while notes were being generated. Retry to create a version with consistent model provenance."
        case .unsupportedModel(let name): return "The Ollama model “\(name)” cannot generate meeting notes locally."
        }
    }
}

public actor OllamaNotesClient {
    private static let baseURL = URL(string: "http://127.0.0.1:11434")!
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 600
            configuration.httpCookieStorage = nil
            self.session = URLSession(configuration: configuration, delegate: LocalOnlyRedirectDelegate(), delegateQueue: nil)
        }
    }

    public func models() async throws -> [OllamaModel] {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 3
        do {
            let (data, response) = try await session.data(for: request)
            try Self.validate(response)
            let candidates = try Self.compatibleModels(from: data)
            var compatible: [OllamaModel] = []
            for model in candidates where try await supportsCompletion(model) { compatible.append(model) }
            return compatible
        } catch is CancellationError { throw CancellationError() }
        catch let error as OllamaNotesError { throw error }
        catch is DecodingError { throw OllamaNotesError.invalidResponse }
        catch { throw OllamaNotesError.unavailable }
    }

    private func supportsCompletion(_ model: OllamaModel) async throws -> Bool {
        if Self.cloudTag(model.name) { return false }
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("api/show")); request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model.name])
        let (data, response) = try await session.data(for: request); try Self.validate(response)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw OllamaNotesError.invalidResponse }
        guard Self.runsLocally(object) else { return false }
        if let capabilities = object["capabilities"] as? [String] { return capabilities.contains("completion") }
        // Older local Ollama releases did not return capabilities. Locality was
        // already established from the show payload.
        return true
    }

    /// Cloud models report `remote_model` or `remote_host` from `/api/show`.
    /// Empty omitempty fields are not proof of a local runner. Require local
    /// weight metadata and reject anything whose locality is unclear.
    public nonisolated static func runsLocally(_ object: [String: Any]) -> Bool {
        if !remoteFieldIsEmpty(object["remote_model"]) || !remoteFieldIsEmpty(object["remote_host"]) { return false }
        guard let info = object["model_info"] as? [String: Any], !info.isEmpty else { return false }
        return true
    }

    private nonisolated static func remoteFieldIsEmpty(_ value: Any?) -> Bool {
        switch value {
        case nil: return true
        case let text as String: return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default: return false
        }
    }

    public func version() async throws -> String {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("api/version")); request.timeoutInterval = 3
        do {
            let (data, response) = try await session.data(for: request); try Self.validate(response)
            guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any], let version = value["version"] as? String else { throw OllamaNotesError.invalidResponse }
            return version
        } catch is CancellationError { throw CancellationError() }
        catch let error as OllamaNotesError { throw error }
        catch { throw OllamaNotesError.unavailable }
    }

    func requireModel(_ selection: ModelSelection) async throws -> OllamaModel {
        guard selection.provider == .ollama else { throw OllamaNotesError.unsupportedModel(selection.id) }
        guard let model = try await models().first(where: { $0.name == selection.id }) else { throw OllamaNotesError.modelMissing(selection.id) }
        guard model.digest == selection.revision else { throw OllamaNotesError.modelChanged(selection.id) }
        return model
    }

    func chat(model: OllamaModel, evidence: String, repair: Bool) async throws -> String {
        guard try await supportsCompletion(model) else { throw OllamaNotesError.unsupportedModel(model.name) }
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.chatRequest(model: model, evidence: evidence, repair: repair)
        let (data, response) = try await session.data(for: request)
        try Self.validate(response)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = object["message"] as? [String: Any],
              let content = message["content"] as? String, !content.isEmpty else { throw OllamaNotesError.invalidResponse }
        return content
    }

    func unload(_ model: OllamaModel) async {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model.name, "messages": [], "stream": false, "keep_alive": 0])
        _ = try? await session.data(for: request)
    }

    public nonisolated static func compatibleModels(from data: Data) throws -> [OllamaModel] {
            struct Response: Decodable {
            struct Item: Decodable {
                struct Details: Decodable { var family: String? }
                var name: String
                var model: String?
                var size: Int64
                var digest: String
                var details: Details?
                var remoteModel: String?
                var remoteHost: String?
                enum CodingKeys: String, CodingKey {
                    case name, model, size, digest, details
                    case remoteModel = "remote_model"
                    case remoteHost = "remote_host"
                }
            }
            var models: [Item]
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        return response.models.compactMap { item in
            let name = item.model ?? item.name
            let family = item.details?.family?.lowercased() ?? ""
            let lowered = name.lowercased()
            let remote = [item.remoteModel, item.remoteHost].contains { value in
                value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            }
            // A positive download size is not evidence that inference stays on this Mac.
            guard !remote, !Self.cloudTag(name), item.size > 0, !item.digest.isEmpty,
                  !lowered.contains("embed"), !family.contains("bert"), !family.contains("embed") else { return nil }
            return OllamaModel(name: name, digest: item.digest, size: item.size)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Ollama cloud tags use `:cloud` or a suffix such as `:120b-cloud`. A renamed alias will not match; show metadata still has to prove locality.
    public nonisolated static func cloudTag(_ name: String) -> Bool {
        name.lowercased().split(separator: ":").dropFirst().contains { $0 == "cloud" || $0.hasSuffix("-cloud") }
    }

    public nonisolated static func chatRequest(model: OllamaModel, evidence: String, repair: Bool) throws -> Data {
        let item: [String: Any] = ["type": "object", "properties": ["text": ["type": "string"], "evidenceIDs": ["type": "array", "items": ["type": "string"]], "owner": ["type": ["string", "null"]], "dueDate": ["type": ["string", "null"]]], "required": ["text", "evidenceIDs", "owner", "dueDate"]]
        let schema: [String: Any] = ["type": "object", "properties": ["summary": ["type": "array", "items": item], "decisions": ["type": "array", "items": item], "actionItems": ["type": "array", "items": item]], "required": ["summary", "decisions", "actionItems"]]
        let prompt = (repair ? "Return valid JSON matching the supplied schema.\n" : "") + LocalIntelligence.instructions + "\nEvidence:\n" + evidence
        return try JSONSerialization.data(withJSONObject: ["model": model.name, "messages": [["role": "user", "content": prompt]], "stream": false, "think": false, "format": schema, "options": ["temperature": 0, "num_predict": 4096]])
    }

    private nonisolated static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, http.url?.host == "127.0.0.1", (200..<300).contains(http.statusCode) else { throw OllamaNotesError.invalidResponse }
    }
}

private final class LocalOnlyRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
