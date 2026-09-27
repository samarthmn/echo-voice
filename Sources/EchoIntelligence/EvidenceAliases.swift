import Foundation

/// Short prompt references prevent the model from copying opaque storage IDs.
/// Only exact aliases from the current batch can become persisted citations.
struct EvidenceAliases {
    private var references: [String: String] = [:]
    private var identifiers: [String: String] = [:]

    init(ids: [String]) {
        for id in ids where references[id] == nil {
            let reference = "E\(references.count + 1)"
            references[id] = reference
            identifiers[reference] = id
        }
    }

    func reference(for id: String) -> String? { references[id] }
    func id(for reference: String) -> String? { identifiers[reference] }

    func resolve(_ values: [String], allowed: Set<String>) -> [String]? {
        guard !values.isEmpty else { return nil }
        var result: [String] = []
        for value in values {
            guard let id = identifiers[value], allowed.contains(id) else { return nil }
            result.append(id)
        }
        return result
    }
}
