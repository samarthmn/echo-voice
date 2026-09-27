import Foundation

public struct AppPaths: Sendable, Equatable {
    public let root: URL
    public let databaseURL: URL
    public let meetingsURL: URL
    public let runtimeURL: URL
    public let modelsURL: URL

    public init(root: URL) {
        let normalizedRoot = root.standardizedFileURL
        self.root = normalizedRoot
        databaseURL = normalizedRoot.appendingPathComponent("echo.sqlite", isDirectory: false)
        meetingsURL = normalizedRoot.appendingPathComponent("meetings", isDirectory: true)
        runtimeURL = normalizedRoot.appendingPathComponent("runtime", isDirectory: true)
        modelsURL = normalizedRoot.appendingPathComponent("models", isDirectory: true)
    }

    public static var `default`: AppPaths {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return AppPaths(root: applicationSupport.appendingPathComponent("EchoVoice", isDirectory: true))
    }

    public func meetingDirectory(_ id: String) -> URL {
        meetingsURL.appendingPathComponent(id, isDirectory: true)
    }

    public func resolveMeetingAsset(meetingID: String, relativePath: String) throws -> URL {
        guard Self.isSafeIdentifier(meetingID) else {
            throw EchoCoreError.invalidIdentifier(meetingID)
        }
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.hasPrefix("~") else {
            throw EchoCoreError.invalidRelativePath(relativePath)
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") }) else {
            throw EchoCoreError.invalidRelativePath(relativePath)
        }

        let canonicalRoot = root.resolvingSymlinksInPath()
        let canonicalMeetings = meetingsURL.resolvingSymlinksInPath()
        let rootPrefix = canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/"
        guard canonicalMeetings.path.hasPrefix(rootPrefix) else {
            throw EchoCoreError.invalidRelativePath(relativePath)
        }

        let base = meetingDirectory(meetingID).standardizedFileURL.resolvingSymlinksInPath()
        let meetingsPrefix = canonicalMeetings.path.hasSuffix("/") ? canonicalMeetings.path : canonicalMeetings.path + "/"
        guard base.path.hasPrefix(meetingsPrefix), base.path != canonicalMeetings.path else {
            throw EchoCoreError.invalidRelativePath(relativePath)
        }
        let candidate = base.appendingPathComponent(relativePath, isDirectory: false)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let basePrefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
        guard candidate.path.hasPrefix(basePrefix), candidate.path != base.path else {
            throw EchoCoreError.invalidRelativePath(relativePath)
        }
        return candidate
    }

    static func isSafeIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128 else { return false }
        return value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) ||
            (byte >= 65 && byte <= 90) ||
            (byte >= 97 && byte <= 122) ||
            byte == 45 || byte == 95
        }
    }
}
