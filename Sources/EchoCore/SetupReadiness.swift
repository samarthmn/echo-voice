import Foundation

public enum PermissionState: String, Codable, Sendable {
    case granted, notDetermined, denied
}

/// Bytes completed toward one model download, summed across its dependency assets.
public struct DownloadTally: Sendable, Equatable {
    public let totalBytes: Int64
    private let assetSizes: [String: Int64]
    private var completed: [String: Int64] = [:]

    public init(assetSizes: [String: Int64]) {
        self.assetSizes = assetSizes
        totalBytes = assetSizes.values.reduce(0, +)
    }
    public init(catalog: ModelCatalog, modelID: String) {
        self.init(assetSizes: Dictionary(uniqueKeysWithValues: catalog.assets(includingDependenciesOf: modelID).map { ($0, catalog.assetBytes($0)) }))
    }
    public mutating func record(asset: String, completedBytes: Int64) {
        guard let size = assetSizes[asset] else { return }
        completed[asset] = min(size, max(completed[asset] ?? 0, completedBytes))
    }
    public mutating func markComplete(asset: String) {
        guard let size = assetSizes[asset] else { return }
        completed[asset] = size
    }
    public var completedBytes: Int64 { completed.values.reduce(0, +) }
    public var fraction: Double { totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) : 0 }
}

public struct SetupReadiness: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable, Identifiable {
        case runtime, speech, notes, speakers, microphone, meetingAudio
        public var id: String { rawValue }
    }
    public enum ItemState: Sendable, Equatable {
        case checking, ready, off, informational
        case inProgress(Double?)
        case actionNeeded
        case problem
    }
    public struct Item: Sendable, Equatable, Identifiable {
        public var kind: Kind
        public var title: String
        public var detail: String
        public var state: ItemState
        public var optional: Bool
        public var id: String { kind.rawValue }
    }
    public enum Overall: Sendable, Equatable {
        case checking, ready, setupRequired, permissionNeeded
        case downloading(Double?)
        case attention(String)
    }
    public enum OptionalModel: Sendable, Equatable {
        case off
        case ready(String)
        case needsDownload(id: String, name: String)
        case unavailable(String)
    }
    public struct Download: Sendable, Equatable {
        public var modelID: String
        public var name: String
        public var fraction: Double?
        public init(modelID: String, name: String, fraction: Double?) { self.modelID = modelID; self.name = name; self.fraction = fraction }
    }
    public struct Inputs: Sendable, Equatable {
        public var libraryProblem: String?
        public var libraryReady = false
        public var runtimeChecked = false
        public var runtimeAvailable = false
        public var runtimeBundled = true
        public var speechModelID = ""
        public var speechModelName: String?
        public var speechReady = false
        public var notes = OptionalModel.off
        public var speakers = OptionalModel.off
        public var microphone = PermissionState.notDetermined
        public var meetingAudio = PermissionState.notDetermined
        public var download: Download?
        public var queuedDownloads = 0
        public init() {}
    }

    public let items: [Item]
    public let overall: Overall
    /// Recording works with no downloads beyond this; notes, speakers and permissions can follow.
    public let requiredComplete: Bool

    public init(_ inputs: Inputs) {
        func downloading(_ id: String) -> Double?? {
            guard let download = inputs.download, download.modelID == id else { return nil }
            return .some(download.fraction)
        }
        var items: [Item] = []

        let runtimeState: ItemState
        let runtimeDetail: String
        if !inputs.runtimeChecked { runtimeState = .checking; runtimeDetail = "Checking the local speech runtime…" }
        else if inputs.runtimeAvailable { runtimeState = .ready; runtimeDetail = inputs.runtimeBundled ? "Included with Echo Voice." : "Installed on this Mac." }
        else if inputs.runtimeBundled { runtimeState = .problem; runtimeDetail = "The included runtime could not start. Reinstall Echo Voice from its official download." }
        else { runtimeState = .actionNeeded; runtimeDetail = "Install the local runtime to process recordings on this Mac." }
        items.append(Item(kind: .runtime, title: "Local runtime", detail: runtimeDetail, state: runtimeState, optional: false))

        let speechName = inputs.speechModelName ?? "Speech model"
        let speechState: ItemState
        let speechDetail: String
        if let fraction = downloading(inputs.speechModelID) { speechState = .inProgress(fraction); speechDetail = "Downloading \(speechName)…" }
        else if inputs.speechReady { speechState = .ready; speechDetail = speechName + " is downloaded and verified." }
        else if inputs.speechModelName == nil { speechState = .actionNeeded; speechDetail = "Choose a speech model to turn recordings into text." }
        else { speechState = .actionNeeded; speechDetail = "Download \(speechName) to turn recordings into text." }
        items.append(Item(kind: .speech, title: "Speech recognition", detail: speechDetail, state: speechState, optional: false))

        func optionalItem(_ kind: Kind, title: String, _ model: OptionalModel, offDetail: String) -> Item {
            switch model {
            case .off: return Item(kind: kind, title: title, detail: offDetail, state: .off, optional: true)
            case .ready(let name): return Item(kind: kind, title: title, detail: name + " is ready.", state: .ready, optional: true)
            case .needsDownload(let id, let name):
                if let fraction = downloading(id) { return Item(kind: kind, title: title, detail: "Downloading \(name)…", state: .inProgress(fraction), optional: true) }
                return Item(kind: kind, title: title, detail: "Download \(name) to use it.", state: .actionNeeded, optional: true)
            case .unavailable(let name): return Item(kind: kind, title: title, detail: name + " is not available right now.", state: .actionNeeded, optional: true)
            }
        }
        items.append(optionalItem(.notes, title: "Meeting notes", inputs.notes, offDetail: "Off. Transcripts still work without notes."))
        items.append(optionalItem(.speakers, title: "Speaker grouping", inputs.speakers, offDetail: "Off. Transcripts show You and Remote speaker."))

        let micState: ItemState
        let micDetail: String
        switch inputs.microphone {
        case .granted: micState = .ready; micDetail = "Echo Voice can record your microphone."
        case .notDetermined: micState = .actionNeeded; micDetail = "Not yet allowed. macOS asks when you grant access or start recording."
        case .denied: micState = .problem; micDetail = "Access denied. Allow Echo Voice in System Settings → Privacy & Security → Microphone."
        }
        items.append(Item(kind: .microphone, title: "Microphone access", detail: micDetail, state: micState, optional: false))

        let audioState: ItemState
        let audioDetail: String
        switch inputs.meetingAudio {
        case .granted: audioState = .ready; audioDetail = "Meeting app audio was captured successfully."
        case .notDetermined: audioState = .informational; audioDetail = "macOS asks the first time you record or test a meeting app. Not needed for in-person recordings."
        case .denied: audioState = .problem; audioDetail = "The last attempt was blocked. Allow Echo Voice under System Audio Recording in System Settings → Privacy & Security."
        }
        items.append(Item(kind: .meetingAudio, title: "Meeting app audio", detail: audioDetail, state: audioState, optional: true))

        self.items = items
        requiredComplete = inputs.runtimeAvailable && inputs.speechReady

        if let problem = inputs.libraryProblem { overall = .attention(problem) }
        else if !inputs.libraryReady || !inputs.runtimeChecked { overall = .checking }
        else if let download = inputs.download { overall = .downloading(download.fraction) }
        else if !requiredComplete { overall = .setupRequired }
        else if inputs.microphone != .granted { overall = .permissionNeeded }
        else { overall = .ready }
    }

    public func item(_ kind: Kind) -> Item? { items.first { $0.kind == kind } }
}
