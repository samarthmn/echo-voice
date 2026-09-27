import Foundation

public enum NotesResponse {
    /// Harmony analysis must never be parsed as final meeting notes.
    public static func finalText(_ response: String, modelID: String) throws -> String {
        if modelID == "gptoss" {
            guard let marker = response.range(of: "<|channel|>final<|message|>", options: .backwards) else { throw IntelligenceError.malformedResponse }
            return String(response[marker.upperBound...]).components(separatedBy:"<|return|>").first ?? ""
        }
        if let end = response.range(of: "</think>", options: .backwards) { return String(response[end.upperBound...]) }
        if response.contains("<think>") { throw IntelligenceError.malformedResponse }
        return response
    }
}
