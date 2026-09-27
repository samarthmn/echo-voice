import Foundation

public enum IntelligenceError: LocalizedError {
    case modelMissing(String), malformedResponse, noEvidence, cancelled
    public var errorDescription: String? {
        switch self {
        case .modelMissing(let name): return "Install the \(name) model in Settings before continuing."
        case .malformedResponse: return "The local model did not return a supported notes draft. Your transcript is safe; try again."
        case .noEvidence: return "There is no finalized evidence to summarize yet."
        case .cancelled: return "Analysis was paused for recording."
        }
    }
}

public enum EvidenceValidator {
    public static func isSupported(_ references: [String], allowed: Set<String>) -> Bool {
        !references.isEmpty && references.allSatisfy { allowed.contains($0) }
    }

    public static func supportsCommitment(_ references: [String], allowed: Set<String>, transcriptIDs: Set<String>) -> Bool {
        isSupported(references, allowed: allowed) && references.contains { transcriptIDs.contains($0) }
    }

    public static func boundedParts(_ text: String, limit: Int = 8000) -> [String] {
        var remainder = text[...], result: [String] = []
        while !remainder.isEmpty {
            let end = remainder.index(remainder.startIndex, offsetBy: max(1, limit), limitedBy: remainder.endIndex) ?? remainder.endIndex
            result.append(String(remainder[..<end])); remainder = remainder[end...]
        }
        return result
    }

    public static func jsonObject(from response: String) throws -> Data {
        // Parse balanced objects, respecting braces inside JSON strings. Do not execute model output.
        var depth = 0, quoted = false, escaped = false
        var start: String.Index?
        for index in response.indices {
            let character = response[index]
            if quoted {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { quoted = false }
                continue
            }
            if character == "\"", depth > 0 { quoted = true; continue }
            if character == "{" { if depth == 0 { start = index }; depth += 1 }
            if character == "}", depth > 0 {
                depth -= 1
                if depth == 0, let start {
                    let data = Data(response[start...index].utf8)
                    if (try? JSONSerialization.jsonObject(with: data)) is [String: Any] { return data }
                }
            }
        }
        throw IntelligenceError.malformedResponse
    }

    public static func batches(_ values: [String], characterBudget: Int) -> [[String]] {
        let budget = max(1, characterBudget)
        var result: [[String]] = [], current: [String] = [], count = 0
        for value in values {
            if !current.isEmpty && count + value.count > budget {
                result.append(current); current = []; count = 0
            }
            current.append(value); count += value.count
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
