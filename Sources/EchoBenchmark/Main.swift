import Foundation
import EchoCore
import EchoIntelligence

/// Headless benchmark using the same notes implementation as the application.
@main enum EchoBenchmark {
    static func main() async {
        do {
            let args = CommandLine.arguments
            guard args.count == 6 else { throw HarnessError.usage }
            let input = URL(fileURLWithPath: args[1]), output = URL(fileURLWithPath: args[2])
            let models = URL(fileURLWithPath: args[3]), manifest = URL(fileURLWithPath: args[4]), modelID = args[5]
            struct Input: Decodable { var segments: [TranscriptSegment] }
            let segments = try JSONDecoder().decode(Input.self, from: Data(contentsOf: input)).segments
            let ollama = OllamaNotesClient()
            let intelligence = LocalIntelligence(modelsURL: models, manifestURL: manifest, ollama: ollama)
            let meeting = Meeting(id: "benchmark", title: "Local accuracy benchmark", startedAt: Date(timeIntervalSince1970: 0), endedAt: Date(timeIntervalSince1970: segments.map(\.endTime).max() ?? 0), state: .ready, language: "en", sourceName: "Fixture", usesEchoCancellation: false, transcriptRevision: 0)
            let start = Date()
            let selection: ModelSelection
            var runtimeVersion: String? = nil
            if modelID.hasPrefix("ollama:") {
                let name = String(modelID.dropFirst("ollama:".count))
                guard let installed = try await ollama.models().first(where: { $0.name == name }) else { throw HarnessError.modelMissing }
                selection = ModelSelection(id: installed.name, revision: installed.digest, provider: .ollama)
                runtimeVersion = try await ollama.version()
            } else {
                let catalog = try ModelCatalog(url: manifest)
                guard let descriptor = catalog.model(modelID) else { throw HarnessError.modelMissing }
                selection = ModelSelection(id: descriptor.id, revision: descriptor.revision)
            }
            let notes = try await intelligence.generateNotes(meeting: meeting, segments: segments, selection: selection) { message in
                FileHandle.standardError.write(Data((message + "\n").utf8))
            }
            struct Result: Encodable { var notes: MeetingNotes; var elapsedSeconds: Double; var provider: ModelProvider; var model: String; var digest: String; var runtimeVersion: String? }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(Result(notes: notes, elapsedSeconds: Date().timeIntervalSince(start), provider: selection.provider, model: selection.id, digest: selection.revision, runtimeVersion: runtimeVersion)).write(to: output, options: .atomic)
            await intelligence.releaseCache()
        } catch {
            FileHandle.standardError.write(Data(("Notes benchmark failed: \(error)\n").utf8)); exit(1)
        }
    }
    enum HarnessError: Error { case usage, modelMissing }
}
