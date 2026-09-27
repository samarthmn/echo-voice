import Foundation
import CryptoKit

public enum ModelRole: String, Codable, Sendable, CaseIterable { case speech, notes, speakers }
public struct ModelDescriptor: Codable, Sendable, Identifiable, Equatable {
    public struct Asset: Codable, Sendable, Equatable { public var path: String; public var size: Int64; public var sha256: String?; public var git_blob_sha1: String? }
    public var id: String
    public var role: ModelRole
    public var display_name: String
    public var repo: String
    public var revision: String
    public var adapter: String
    public var dependencies: [String]
    public var estimated_memory_bytes: Int64
    public var download_bytes: Int64
    public var timing: String
    public var vocabulary: String
    public var gated: Bool
    public var license: String
    public var files: [Asset]
    public var displayName: String { display_name }
}
public struct ModelCatalog: Sendable {
    public let models: [ModelDescriptor]
    public let schema: Int
    private let assetSizes: [String: Int64]
    private let assetDependencies: [String: [String]]
    public init(url: URL) throws {
        struct Envelope: Decodable { var schema: Int; var models: [String: Raw] }
        struct Raw: Decodable {
            let role: String?
            let descriptor: ModelDescriptor?
            let size: Int64
            let dependencies: [String]
            init(from decoder: Decoder) throws {
                struct Role: Decodable { var role: String?; var download_bytes: Int64?; var dependencies: [String]?; var files: [ModelDescriptor.Asset]? }
                let metadata = try Role(from: decoder)
                role = metadata.role; size = metadata.download_bytes ?? metadata.files?.reduce(0, { $0 + $1.size }) ?? 0; dependencies = metadata.dependencies ?? []
                descriptor = ModelRole(rawValue: role ?? "") == nil ? nil : try ModelDescriptor(from: decoder)
            }
        }
        let value = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url))
        guard value.schema == 2 else { throw CatalogError.invalid }
        schema = value.schema
        assetSizes = value.models.mapValues(\.size)
        assetDependencies = value.models.mapValues(\.dependencies)
        models = value.models.values.compactMap(\.descriptor).sorted { $0.displayName < $1.displayName }
        guard Set(models.map(\.id)).count == models.count,
              models.allSatisfy({ $0.revision.count == 40 && !$0.files.isEmpty && $0.id.range(of: "^[a-z0-9]+$", options: .regularExpression) != nil }) else { throw CatalogError.invalid }
    }
    public static var bundledURL: URL { (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent("service/models.json") }
    public func downloadBytes(includingDependenciesOf id: String) -> Int64 {
        var visited = Set<String>()
        func total(_ key: String) -> Int64 {
            guard visited.insert(key).inserted else { return 0 }
            return (assetSizes[key] ?? 0) + (assetDependencies[key] ?? []).reduce(0) { $0 + total($1) }
        }
        return total(id)
    }
    /// Setup reports progress per asset; this is the set a single model download touches.
    public func assets(includingDependenciesOf id: String) -> [String] {
        var ordered: [String] = []
        func visit(_ key: String) {
            guard !ordered.contains(key) else { return }
            ordered.append(key)
            for dependency in assetDependencies[key] ?? [] { visit(dependency) }
        }
        visit(id)
        return ordered
    }
    public func assetBytes(_ id: String) -> Int64 { assetSizes[id] ?? 0 }
    public func model(_ id: String) -> ModelDescriptor? { models.first { $0.id == id } }
    public func models(for role: ModelRole) -> [ModelDescriptor] { models.filter { $0.role == role } }
    public enum CatalogError: Error { case invalid }
}
public enum ModelProvider: String, Codable, Sendable, CaseIterable {
    case native, ollama
}
public struct ModelSelection: Codable, Sendable, Equatable {
    public var id: String
    public var revision: String
    public var provider: ModelProvider
    public init(id: String, revision: String, provider: ModelProvider = .native) {
        self.id = id; self.revision = revision; self.provider = provider
    }
    private enum CodingKeys: String, CodingKey { case id, revision, provider }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        revision = try values.decode(String.self, forKey: .revision)
        provider = try values.decodeIfPresent(ModelProvider.self, forKey: .provider) ?? .native
    }
}
public struct ProcessingConfiguration: Codable, Sendable, Equatable {
    public var speech: ModelSelection
    public var notes: ModelSelection?
    public var speakers: ModelSelection?
    public var vocabulary: [VocabularyEntry]
    public var fuzzyVocabulary: Bool
    public var language = "en"
    public var pipelineVersion = "accuracy-word-v2"
    public var recordingMode: RecordingMode?
    public var id: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: (try? encoder.encode(self)) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }
    public init(speech: ModelSelection, notes: ModelSelection? = nil, speakers: ModelSelection? = nil, vocabulary: [VocabularyEntry] = [], fuzzyVocabulary: Bool = false) {
        self.speech = speech; self.notes = notes; self.speakers = speakers; self.vocabulary = vocabulary; self.fuzzyVocabulary = fuzzyVocabulary
    }
}
public struct VocabularyEntry: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var spelling: String
    public var aliases: [String]
    public var enabled: Bool
    public var important: Bool
    public init(id: String = UUID().uuidString, spelling: String, aliases: [String] = [], enabled: Bool = true, important: Bool = false) {
        self.id = id; self.spelling = spelling; self.aliases = aliases; self.enabled = enabled; self.important = important
    }
    public static func validated(_ entries: [Self]) throws -> [Self] {
        func normalized(_ value: String) -> String { value.precomposedStringWithCompatibilityMapping.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        guard entries.filter(\.enabled).count <= 500 else { throw VocabularyError.tooMany }
        var spellings = Set<String>(), identifiers = Set<String>(), aliases: [String: String] = [:]
        var output: [Self] = []
        for var entry in entries {
            entry.spelling = normalized(entry.spelling); entry.aliases = entry.aliases.map(normalized)
            guard !entry.id.isEmpty, identifiers.insert(entry.id).inserted, !entry.spelling.isEmpty, entry.spelling.count <= 50,
                  spellings.insert(entry.spelling.lowercased()).inserted,
                  entry.aliases.allSatisfy({ !$0.isEmpty && $0.count <= 50 }) else { throw VocabularyError.invalid }
            for alias in entry.aliases {
                let key = alias.lowercased()
                guard aliases[key] == nil || aliases[key] == entry.id else { throw VocabularyError.ambiguous }
                aliases[key] = entry.id
            }
            output.append(entry)
        }
        for entry in output where aliases[entry.spelling.lowercased()] != nil && aliases[entry.spelling.lowercased()] != entry.id { throw VocabularyError.ambiguous }
        return output
    }
    public enum VocabularyError: LocalizedError {
        case tooMany, invalid, ambiguous
        public var errorDescription: String? {
            switch self {
            case .tooMany: return "Use at most 500 vocabulary entries."
            case .invalid: return "Use unique spellings and aliases containing 1–50 characters."
            case .ambiguous: return "An alias can belong to only one preferred spelling."
            }
        }
    }
}
public struct ModelInstallation: Sendable, Equatable {
    public enum State: String, Codable, Sendable { case notDownloaded, downloading, verifying, ready, cancelled, needsAccess, failed, removing }
    public var modelID: String
    public var state: State
    public var completedBytes: Int64 = 0
    public var totalBytes: Int64 = 0
    public var error: String?
}
