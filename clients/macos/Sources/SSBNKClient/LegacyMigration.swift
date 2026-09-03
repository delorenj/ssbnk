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
            return "The new SSH route must be Healthy before the legacy uploader can be retired."
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
        guard let result = try? await runner.run(SSBNKCommands.legacyAgentStatus(uid: uid)) else { return false }
        return result.succeeded
    }

    func retire(replacementHealth: ClientHealthState, confirmed: Bool) async throws {
        guard confirmed else { throw LegacyMigrationError.confirmationRequired }
        guard replacementHealth == .healthy else { throw LegacyMigrationError.replacementNotHealthy }

        let status: CommandResult
        do {
            status = try await runner.run(SSBNKCommands.legacyAgentStatus(uid: uid))
        } catch {
            throw LegacyMigrationError.couldNotDisableAgent(error.localizedDescription)
        }
        if status.succeeded {
            let result: CommandResult
            do {
                result = try await runner.run(SSBNKCommands.disableLegacyAgent(uid: uid))
            } catch {
                throw LegacyMigrationError.couldNotDisableAgent(error.localizedDescription)
            }
            guard result.succeeded else {
                let detail = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
                throw LegacyMigrationError.couldNotDisableAgent(
                    detail.isEmpty ? "launchctl exited with status \(result.exitCode)" : detail
                )
            }
        } else if !Self.meansServiceIsMissing(status) {
            let detail = status.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            throw LegacyMigrationError.couldNotDisableAgent(
                detail.isEmpty ? "could not determine whether the legacy job is loaded" : detail
            )
        }

        if fileManager.fileExists(atPath: artifacts.launchAgentPlist.path) {
            try fileManager.removeItem(at: artifacts.launchAgentPlist)
        }

        if fileManager.fileExists(atPath: artifacts.credentialConfiguration.path) {
            try fileManager.removeItem(at: artifacts.credentialConfiguration)
        }
    }

    private static func meansServiceIsMissing(_ result: CommandResult) -> Bool {
        result.standardError.localizedCaseInsensitiveContains("could not find service")
            || result.standardError.localizedCaseInsensitiveContains("no such process")
            || result.standardError.localizedCaseInsensitiveContains("service not found")
    }
}
