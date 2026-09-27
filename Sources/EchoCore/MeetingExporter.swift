import Foundation

public final class MeetingExporter: Sendable {
    private let store: MeetingStore

    public init(store: MeetingStore) {
        self.store = store
    }

    public func export(meetingID: String, to destination: URL) throws -> URL {
        let snapshot = try store.exportSnapshot(meetingID: meetingID)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        let temporary = destination.appendingPathComponent(".echo-export-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporary, withIntermediateDirectories: false)
        do {
            try writeTranscripts(snapshot, to: temporary)
            let exportedSnapshot = try copyAssets(snapshot, to: temporary)
            try writeNotes(exportedSnapshot, to: temporary)
            try writeManifest(exportedSnapshot, to: temporary)

            let baseName = Self.safeFilename(snapshot.meeting.title.isEmpty ? snapshot.meeting.id : snapshot.meeting.title)
            let final = Self.availableDestination(in: destination, baseName: baseName, fileManager: fileManager)
            try fileManager.moveItem(at: temporary, to: final)
            return final
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }
}

private extension MeetingExporter {
    func writeManifest(_ snapshot: ExportSnapshot, to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        try data.write(to: directory.appendingPathComponent("meeting.json"), options: .atomic)
    }

    func writeTranscripts(_ snapshot: ExportSnapshot, to directory: URL) throws {
        let plainText = snapshot.segments.map(\.text).joined(separator: "\n") + (snapshot.segments.isEmpty ? "" : "\n")
        try Data(plainText.utf8).write(to: directory.appendingPathComponent("transcript.txt"), options: .atomic)

        let speakerLabels = Dictionary(uniqueKeysWithValues: snapshot.speakers.map { ($0.id, $0.label) })
        var markdown = "# \(Self.escapeMarkdown(snapshot.meeting.title))\n\n"
        markdown += "Started: \(ISO8601DateFormatter().string(from: snapshot.meeting.startedAt))\n\n"
        markdown += "## Transcript\n\n"
        for segment in snapshot.segments {
            let time = Self.formatTime(segment.startTime)
            markdown += "<a id=\"\(Self.segmentAnchor(segment.id))\"></a>\n\n"
            if let speakerID = segment.speakerID {
                let label = speakerLabels[speakerID] ?? speakerID
                markdown += "**[\(time)] \(Self.escapeMarkdown(label)):** \(segment.text)\n\n"
            } else {
                markdown += "**[\(time)]** \(segment.text)\n\n"
            }
        }
        markdown += "## Highlights and bookmarks\n\n"
        for item in snapshot.annotations {
            markdown += "- [" + Self.formatTime(item.startTime) + "] " + Self.escapeMarkdown(item.quote ?? item.label ?? "Bookmark") + "\n"
        }
        try Data(markdown.utf8).write(to: directory.appendingPathComponent("transcript.md"), options: .atomic)
    }

    func writeNotes(_ snapshot: ExportSnapshot, to directory: URL) throws {
        guard let notes = snapshot.notes.first else { return }
        var markdown = "# Notes: \(Self.escapeMarkdown(snapshot.meeting.title))\n\n"
        append(items: notes.summary, heading: "Summary", snapshot: snapshot, to: &markdown)
        append(items: notes.decisions, heading: "Decisions", snapshot: snapshot, to: &markdown)
        append(items: notes.actionItems, heading: "Action items", snapshot: snapshot, to: &markdown)
        try Data(markdown.utf8).write(to: directory.appendingPathComponent("notes.md"), options: .atomic)
    }

    func append(items: [NoteItem], heading: String, snapshot: ExportSnapshot, to markdown: inout String) {
        guard !items.isEmpty else { return }
        markdown += "## \(heading)\n\n"
        for item in items {
            markdown += "- \(item.text)"
            if let owner = item.owner { markdown += " — \(owner)" }
            if let dueDate = item.dueDate { markdown += " (due \(dueDate))" }
            let references = item.evidenceIDs.compactMap { id -> String? in
                if let segment = snapshot.segments.first(where: { $0.id == id }) {
                    return "[\(Self.formatTime(segment.startTime))](transcript.md#\(Self.segmentAnchor(id)))"
                }
                if let screenshot = snapshot.screenshots.first(where: { $0.id == id }) {
                    // Escape filenames as URL components, preserving directory separators.
                    let path = screenshot.relativePath.split(separator: "/").map {
                        String($0).addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) ?? ""
                    }.joined(separator: "/")
                    return "[Screenshot \(Self.formatTime(screenshot.capturedAt))](\(path))"
                }
                return nil
            }
            if !references.isEmpty { markdown += " — Evidence: " + references.joined(separator: ", ") }
            markdown += "\n"
        }
        markdown += "\n"
    }

    func copyAssets(_ snapshot: ExportSnapshot, to directory: URL) throws -> ExportSnapshot {
        let fileManager = FileManager.default
        var usedDestinations = Set<String>()
        var exportedChunks: [CapturedChunk] = []
        for chunk in snapshot.chunks {
            let lease = try store.audioAssets.acquireSync(chunk: chunk)
            let source = lease.url
            let trackName = snapshot.meeting.recordingMode == .inPerson && chunk.track == .microphone ? "room-microphone" : chunk.track.rawValue
            let trackDirectory = directory
                .appendingPathComponent("audio", isDirectory: true)
                .appendingPathComponent(trackName, isDirectory: true)
            try fileManager.createDirectory(at: trackDirectory, withIntermediateDirectories: true)
            let destination = uniqueAssetDestination(
                preferredName: source.lastPathComponent,
                fallbackID: chunk.id,
                directory: trackDirectory,
                used: &usedDestinations
            )
            try fileManager.copyItem(at: source, to: destination)
            var exported = chunk
            exported.relativePath = "audio/\(trackName)/\(destination.lastPathComponent)"
            exportedChunks.append(exported)
        }

        var exportedScreenshots: [ScreenshotRecord] = []
        if !snapshot.screenshots.isEmpty {
            let screenshotsDirectory = directory.appendingPathComponent("screenshots", isDirectory: true)
            try fileManager.createDirectory(at: screenshotsDirectory, withIntermediateDirectories: true)
            for screenshot in snapshot.screenshots {
                let source = try store.validatedAssetURL(
                    meetingID: snapshot.meeting.id,
                    relativePath: screenshot.relativePath
                )
                let destination = uniqueAssetDestination(
                    preferredName: source.lastPathComponent,
                    fallbackID: screenshot.id,
                    directory: screenshotsDirectory,
                    used: &usedDestinations
                )
                try fileManager.copyItem(at: source, to: destination)
                var exported = screenshot
                exported.relativePath = "screenshots/\(destination.lastPathComponent)"
                exportedScreenshots.append(exported)
            }
        }
        return ExportSnapshot(
            meeting: snapshot.meeting,
            chunks: exportedChunks,
            gaps: snapshot.gaps,
            segments: snapshot.segments,
            speakers: snapshot.speakers,
            screenshots: exportedScreenshots,
            notes: snapshot.notes,
            jobs: snapshot.jobs, transcriptVersion: snapshot.transcriptVersion, annotations: snapshot.annotations,
            speakerGrouping: snapshot.speakerGrouping
        )
    }

    func uniqueAssetDestination(
        preferredName: String,
        fallbackID: String,
        directory: URL,
        used: inout Set<String>
    ) -> URL {
        let scopedPreferred = directory.path + "/" + preferredName
        if used.insert(scopedPreferred).inserted {
            return directory.appendingPathComponent(preferredName)
        }
        let safeID = Self.safeFilename(fallbackID)
        let alternate = safeID + "-" + preferredName
        used.insert(directory.path + "/" + alternate)
        return directory.appendingPathComponent(alternate)
    }

    static func availableDestination(in directory: URL, baseName: String, fileManager: FileManager) -> URL {
        var candidate = directory.appendingPathComponent(baseName, isDirectory: true)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        return candidate
    }

    static func safeFilename(_ value: String) -> String {
        let disallowed = CharacterSet(charactersIn: "/\\:\0").union(.controlCharacters)
        let pieces = value.components(separatedBy: disallowed)
        let result = pieces.joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty || result == "." || result == ".." ? "Echo Voice Export" : String(result.prefix(120))
    }

    static func formatTime(_ seconds: Double) -> String {
        let wholeSeconds = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d:%02d", wholeSeconds / 3600, (wholeSeconds / 60) % 60, wholeSeconds % 60)
    }

    static func segmentAnchor(_ id: String) -> String {
        // Hex-encoded UTF-8 is stable and safe in both HTML attributes and URLs.
        "segment-" + id.utf8.map { String(format: "%02x", $0) }.joined()
    }

    static func escapeMarkdown(_ value: String) -> String {
        value.replacingOccurrences(of: "#", with: "\\#")
    }
}
