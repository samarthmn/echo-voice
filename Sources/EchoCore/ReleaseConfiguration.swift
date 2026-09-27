import Foundation

public enum DistributionChannel: String, Sendable {
    case development, direct, appStore
}

public enum ReleaseConfiguration {
    public static var channel: DistributionChannel {
        DistributionChannel(rawValue: Bundle.main.object(forInfoDictionaryKey: "EchoDistributionChannel") as? String ?? "") ?? .development
    }
    public static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development" }
    public static let releasesURL = URL(string: "https://github.com/samarthmn/echo-voice/releases")!
    public static var bundledRuntime: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/EchoRuntime", isDirectory: true)
    }
}

/// Executable code is read from the signed application in shipping builds.
/// Legacy writable runtimes are supported only by development builds.
public struct RuntimeLayout: Sendable {
    public let root: URL
    public let bundled: Bool
    public init(paths: AppPaths) {
        let candidate = ReleaseConfiguration.bundledRuntime
        bundled = ReleaseConfiguration.channel != .development || FileManager.default.fileExists(atPath: candidate.appendingPathComponent("runtime-manifest.json").path)
        root = bundled ? candidate : paths.runtimeURL
    }
    public var python: URL { root.appendingPathComponent(bundled ? "speech/bin/python3.11" : "venv/bin/python") }
    public var voiceStudio: URL { root.appendingPathComponent("vendor/VoiceStudio") }
    public var communityPython: URL { root.appendingPathComponent(bundled ? "community/bin/python3.11" : "community-venv/bin/python") }
    public func environment() -> [String: String] {
        var values = ["ECHO_VOICESTUDIO_ROOT": voiceStudio.path]
        if bundled { values["ECHO_BUNDLED_RUNTIME"] = root.path }
        return values
    }
}
