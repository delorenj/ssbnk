import Foundation

enum MediaKind: String, Codable, CaseIterable, Equatable, Hashable {
    case image
    case video

    var label: String {
        switch self {
        case .image: return "Screenshots"
        case .video: return "Recordings"
        }
    }
}

struct RouteMapping: Codable, Equatable, Identifiable {
    let kind: MediaKind
    let sourceDirectory: String
    let remoteDirectory: String

    var id: MediaKind { kind }
}

enum ConfigurationIssue: Error, Equatable, CustomStringConvertible {
    case captureDirectoryMissing
    case invalidSSHDestination
    case invalidPublicHealthURL
    case invalidRemoteDirectory(MediaKind)

    var description: String {
        switch self {
        case .captureDirectoryMissing:
            return "Choose the folder where macOS saves screenshots and recordings."
        case .invalidSSHDestination:
            return "Enter an SSH destination such as delorenj@big-chungus.burro-salmon.ts.net."
        case .invalidPublicHealthURL:
            return "Enter an HTTPS health URL."
        case .invalidRemoteDirectory(let kind):
            return "Enter a safe absolute server directory for \(kind.label.lowercased())."
        }
    }
}

struct ClientConfiguration: Codable, Equatable {
    var captureDirectory: String
    var sshDestination: String
    var publicHealthURL: String
    var imageRemoteDirectory: String
    var videoRemoteDirectory: String

    static func defaults(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> ClientConfiguration {
        ClientConfiguration(
            captureDirectory: homeDirectory
                .appendingPathComponent("Pictures", isDirectory: true)
                .appendingPathComponent("Screenshots", isDirectory: true)
                .path,
            sshDestination: "delorenj@big-chungus.burro-salmon.ts.net",
            publicHealthURL: "https://ss.delo.sh/health",
            imageRemoteDirectory: "/home/delorenj/Pictures/Screenshots",
            videoRemoteDirectory: "/home/delorenj/Videos/Screencasts"
        )
    }

    var captureURL: URL {
        URL(fileURLWithPath: NSString(string: captureDirectory).expandingTildeInPath, isDirectory: true)
    }

    var healthURL: URL? {
        URL(string: publicHealthURL)
    }

    var mappings: [RouteMapping] {
        [
            RouteMapping(
                kind: .image,
                sourceDirectory: captureDirectory,
                remoteDirectory: imageRemoteDirectory
            ),
            RouteMapping(
                kind: .video,
                sourceDirectory: captureDirectory,
                remoteDirectory: videoRemoteDirectory
            ),
        ]
    }

    func remoteDirectory(for kind: MediaKind) -> String {
        switch kind {
        case .image: return imageRemoteDirectory
        case .video: return videoRemoteDirectory
        }
    }

    func validationIssues() -> [ConfigurationIssue] {
        var issues: [ConfigurationIssue] = []
        if captureDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.captureDirectoryMissing)
        }
        if !Self.isSafeSSHDestination(sshDestination) {
            issues.append(.invalidSSHDestination)
        }
        if !Self.isHTTPSURL(healthURL) {
            issues.append(.invalidPublicHealthURL)
        }
        if !Self.isSafeRemoteDirectory(imageRemoteDirectory) {
            issues.append(.invalidRemoteDirectory(.image))
        }
        if !Self.isSafeRemoteDirectory(videoRemoteDirectory) {
            issues.append(.invalidRemoteDirectory(.video))
        }
        return issues
    }

    private static func isHTTPSURL(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", url.host?.isEmpty == false else {
            return false
        }
        return true
    }

    private static func isSafeSSHDestination(_ destination: String) -> Bool {
        guard !destination.isEmpty,
              !destination.hasPrefix("-"),
              !destination.contains(":"),
              destination.filter({ $0 == "@" }).count <= 1
        else {
            return false
        }

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "@._-"))
        return destination.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func isSafeRemoteDirectory(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.contains(".."), !path.contains("//") else {
            return false
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-"))
        return path.unicodeScalars.allSatisfy(allowed.contains)
    }
}

protocol ConfigurationPersisting {
    func load() throws -> ClientConfiguration?
    func save(_ configuration: ClientConfiguration) throws
}

final class ConfigurationStore: ConfigurationPersisting {
    let fileURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
    }

    func load() throws -> ClientConfiguration? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        return try decoder.decode(ClientConfiguration.self, from: Data(contentsOf: fileURL))
    }

    func save(_ configuration: ClientConfiguration) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(configuration)
        try data.write(to: fileURL, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

enum ApplicationPaths {
    static func supportDirectory(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? homeDirectory.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("SSBNK Client", isDirectory: true)
    }
}
