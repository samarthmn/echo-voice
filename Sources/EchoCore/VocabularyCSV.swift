import Foundation

public enum VocabularyCSV {
    public static func export(_ entries: [VocabularyEntry]) -> String {
        func quoted(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        return "spelling,aliases,enabled,important\r\n" + entries.map { [quoted($0.spelling), quoted($0.aliases.joined(separator: "|")), String($0.enabled), String($0.important)].joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }
    public static func parse(_ text: String) throws -> [VocabularyEntry] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false, afterQuote = false
        let chars = Array(text); var i = 0
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i+1 < chars.count && chars[i+1] == "\"" { field.append(c); i += 1 }
                    else { quoted = false; afterQuote = true }
                } else { field.append(c) }
            } else if c == "," { row.append(field); field = ""; afterQuote = false }
            else if c == "\n" || c == "\r\n" || c == "\r" {
                row.append(field); if row.contains(where: { !$0.isEmpty }) { rows.append(row) }; row = []; field = ""; afterQuote = false
            } else if c == "\"" && field.isEmpty && !afterQuote { quoted = true }
            else { guard !afterQuote else { throw CSVError.invalid }; field.append(c) }
            i += 1
        }
        guard !quoted else { throw CSVError.invalid }
        row.append(field); if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
        guard rows.first == ["spelling", "aliases", "enabled", "important"] else { throw CSVError.invalid }
        let entries = try rows.dropFirst().map { cells -> VocabularyEntry in
            guard cells.count == 4, let enabled = Bool(cells[2]), let important = Bool(cells[3]) else { throw CSVError.invalid }
            return VocabularyEntry(spelling: cells[0], aliases: cells[1].split(separator: "|").map(String.init), enabled: enabled, important: important)
        }
        return try VocabularyEntry.validated(entries)
    }
    public enum CSVError: LocalizedError { case invalid; public var errorDescription: String? { "Use a CSV with spelling, aliases, enabled, and important columns. Separate aliases with |." } }
}
