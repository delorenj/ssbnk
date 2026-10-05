import Foundation
#if os(macOS)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum LegacyMigrationError: Error, LocalizedError, Equatable {
    case confirmationRequired
    case replacementNotHealthy
    case couldNotDisableAgent(String)

    var errorDescription: String? {
        switch self {
        case .confirmationRequired:
            return "Confirm before retiring the legacy uploader."
        case .replacementNotHealthy:
            return "The authenticated HTTP replacement must be Healthy before the legacy uploader can be retired."
        case .couldNotDisableAgent(let detail):
            return "Could not disable the legacy uploader: \(detail)"
        }
    }
}

struct LegacyArtifacts: Equatable {
    let launchAgentPlist: URL
    let credentialConfiguration: URL
}

final class LegacyMigration {
    static let agentLabel = "sh.delo.ss.remote-upload"

    let artifacts: LegacyArtifacts
    private let runner: CommandRunning
    private let fileManager: FileManager
    private let uid: UInt32

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        runner: CommandRunning,
        fileManager: FileManager = .default,
        uid: UInt32 = getuid()
    ) {
        artifacts = LegacyArtifacts(
            launchAgentPlist: homeDirectory
                .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
                .appendingPathComponent("\(Self.agentLabel).plist"),
            credentialConfiguration: homeDirectory
                .appendingPathComponent(".config/ssbnk", isDirectory: true)
                .appendingPathComponent("remote.env")
        )
        self.runner = runner
        self.fileManager = fileManager
        self.uid = uid
    }

    var isPresent: Bool {
        fileManager.fileExists(atPath: artifacts.launchAgentPlist.path)
            || fileManager.fileExists(atPath: artifacts.credentialConfiguration.path)
    }

    func detectPresence() async -> Bool {
        if isPresent { return true }
        guard let result = try? await runner.run(SSBNKCommands.legacyAgentStatus(uid: uid)) else { return true }
        return result.succeeded || !Self.meansServiceIsMissing(result)
    }

    func retire(replacementHealth: ClientHealthState, confirmed: Bool) async throws {
        guard confirmed else { throw LegacyMigrationError.confirmationRequired }
        guard replacementHealth == .healthy else { throw LegacyMigrationError.replacementNotHealthy }
        throw UploadFailure(code: "HANDOVER_REQUIRED", message: "Controlled capture, verified vault migration, durable boundary and rollback qualification are required before legacy retirement. Legacy files were preserved.", retryable: false)
    }

    func cutover(configuration: ClientConfiguration, controlledReady: () async throws -> Void,
                 persistBoundary: () async throws -> Void, commitHandover: () async throws -> Void,
                 confirmed: Bool, credentials: UploadCredentialProviding = UploadCredentialProvider()) async throws {
        guard confirmed else { throw LegacyMigrationError.confirmationRequired }
        let credential = try await credentials.resolve(reference: configuration.credentialReference ?? "")
        if fileManager.fileExists(atPath: artifacts.credentialConfiguration.path) {
            let attributes = try fileManager.attributesOfItem(atPath: artifacts.credentialConfiguration.path)
            guard (attributes[.size] as? NSNumber)?.intValue ?? 65537 <= 65536 else { throw LegacyMigrationError.replacementNotHealthy }
            let contents = try String(contentsOf: artifacts.credentialConfiguration, encoding: .utf8)
            var legacyKey: String?
            for line in contents.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let assignment = trimmed.hasPrefix("export ") ? String(trimmed.dropFirst(7)) : trimmed
                guard assignment.hasPrefix("SSBNK_UPLOAD_KEY=") else { continue }
                var value = String(assignment.dropFirst("SSBNK_UPLOAD_KEY=".count))
                if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" { value = String(value.dropFirst().dropLast()) }
                guard !value.contains("$"), !value.contains("`") else { throw LegacyMigrationError.replacementNotHealthy }
                legacyKey = value
            }
            guard let legacyKey, try CaptureHash.data(Data(legacyKey.utf8)) == CaptureHash.data(Data(credential.utf8)) else {
                throw UploadFailure(code: "VAULT_MIGRATION", message: "Verified vault migration must match the legacy key; plaintext file preserved.", retryable: false)
            }
        }
        try await controlledReady()
        try await persistBoundary()
        let status = try await runner.run(SSBNKCommands.legacyAgentStatus(uid: uid))
        let wasActive = status.succeeded
        guard wasActive || Self.meansServiceIsMissing(status) else { throw LegacyMigrationError.couldNotDisableAgent("legacy status is uncertain") }
        do {
            if wasActive {
                let stopped = try await runner.run(SSBNKCommands.disableLegacyAgent(uid: uid))
                guard stopped.succeeded else { throw LegacyMigrationError.couldNotDisableAgent("launchctl bootout failed") }
            }
            let disabled = try await runner.run(Command(executable: SSBNKCommands.launchctlExecutable, arguments: ["disable", "gui/\(uid)/\(Self.agentLabel)"], timeout: 10))
            guard disabled.succeeded else { throw LegacyMigrationError.couldNotDisableAgent("launchctl disable failed") }
            let inactive = try await runner.run(SSBNKCommands.legacyAgentStatus(uid: uid))
            let processes = try await runner.run(Command(executable: "/usr/bin/pgrep", arguments: ["-u", String(uid), "-f", "remote-screenshot-upload.sh"], timeout: 10))
            guard Self.meansServiceIsMissing(inactive), processes.exitCode == 1 else { throw LegacyMigrationError.couldNotDisableAgent("legacy inactivity was not verified") }
            try await commitHandover()
        } catch {
            _ = try? await runner.run(Command(executable: SSBNKCommands.launchctlExecutable, arguments: ["enable", "gui/\(uid)/\(Self.agentLabel)"], timeout: 10))
            if wasActive { _ = try? await runner.run(Command(executable: SSBNKCommands.launchctlExecutable, arguments: ["bootstrap", "gui/\(uid)", artifacts.launchAgentPlist.path], timeout: 10)) }
            throw error
        }
    }

    private static func meansServiceIsMissing(_ result: CommandResult) -> Bool {
        result.standardError.localizedCaseInsensitiveContains("could not find service")
            || result.standardError.localizedCaseInsensitiveContains("no such process")
            || result.standardError.localizedCaseInsensitiveContains("service not found")
    }
}
