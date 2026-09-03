import Foundation
#if os(macOS)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct Command: Equatable {
    let executable: String
    let arguments: [String]
    var environment: [String: String]? = nil
    var timeout: TimeInterval = 75
}

struct CommandResult: Equatable {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String

    var succeeded: Bool { exitCode == 0 }
}

enum CommandRunnerError: Error, LocalizedError {
    case couldNotLaunch(String)
    case timedOut(seconds: TimeInterval, standardError: String)

    var errorDescription: String? {
        switch self {
        case .couldNotLaunch(let message):
            return message
        case .timedOut(let seconds, let standardError):
            let detail = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "Command timed out after \(Int(seconds)) seconds."
                : "Command timed out after \(Int(seconds)) seconds: \(detail)"
        }
    }
}

protocol CommandRunning {
    func run(_ command: Command) async throws -> CommandResult
}

private final class CommandCompletionState: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var timedOut = false

    func claimCompletion() -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return nil }
        completed = true
        return timedOut
    }

    func requestTimeout() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return false }
        timedOut = true
        return true
    }
}

final class ProcessCommandRunner: CommandRunning, @unchecked Sendable {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func run(_ command: Command) async throws -> CommandResult {
        let captureDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("ssbnk-command-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(
            at: captureDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let outputURL = captureDirectory.appendingPathComponent("stdout")
        let errorURL = captureDirectory.appendingPathComponent("stderr")
        guard fileManager.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              fileManager.createFile(atPath: errorURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else {
            try? fileManager.removeItem(at: captureDirectory)
            throw CommandRunnerError.couldNotLaunch("Could not create private command-output files.")
        }

        let outputHandle = try FileHandle(forWritingTo: outputURL)
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        if let environment = command.environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        process.standardOutput = outputHandle
        process.standardError = errorHandle

        return try await withCheckedThrowingContinuation { continuation in
            let completionState = CommandCompletionState()

            let complete: @Sendable (Error?) -> Void = { launchError in
                guard let didTimeOut = completionState.claimCompletion() else { return }

                try? outputHandle.close()
                try? errorHandle.close()
                let output = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
                let errorOutput = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? ""
                try? self.fileManager.removeItem(at: captureDirectory)

                if let launchError {
                    continuation.resume(throwing: CommandRunnerError.couldNotLaunch(
                        "Could not launch \(command.executable): \(launchError.localizedDescription)"
                    ))
                } else if didTimeOut {
                    continuation.resume(throwing: CommandRunnerError.timedOut(
                        seconds: command.timeout,
                        standardError: errorOutput
                    ))
                } else {
                    continuation.resume(returning: CommandResult(
                        exitCode: process.terminationStatus,
                        standardOutput: output,
                        standardError: errorOutput
                    ))
                }
            }

            process.terminationHandler = { _ in complete(nil) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                complete(error)
                return
            }

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + command.timeout) {
                guard completionState.requestTimeout() else { return }
                if process.isRunning {
                    process.terminate()
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                        if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
                    }
                }
            }
        }
    }
}

enum SSBNKCommands {
    static let sshExecutable = "/usr/bin/ssh"
    static let rsyncExecutable = "/usr/bin/rsync"
    static let launchctlExecutable = "/bin/launchctl"
    static let sshTransport = "/usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=10"
    private static let sshOptions = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]

    static func sshProbe(destination: String) -> Command {
        Command(executable: sshExecutable, arguments: sshOptions + [destination, "/usr/bin/true"], timeout: 15)
    }

    static func remoteWriteProbe(destination: String, directory: String) -> Command {
        Command(
            executable: sshExecutable,
            arguments: sshOptions + [destination, "/usr/bin/test", "-w", directory],
            timeout: 15
        )
    }

    static func rsync(stagedFile: URL, destination: String, remoteDirectory: String) -> Command {
        let directory = remoteDirectory.hasSuffix("/") ? remoteDirectory : remoteDirectory + "/"
        return Command(
            executable: rsyncExecutable,
            arguments: [
                "--recursive",
                "--times",
                "--timeout=60",
                "--rsh=\(sshTransport)",
                "--",
                stagedFile.path,
                "\(destination):\(directory)",
            ],
            timeout: 75
        )
    }

    static func legacyAgentStatus(uid: UInt32) -> Command {
        Command(
            executable: launchctlExecutable,
            arguments: ["print", "gui/\(uid)/\(LegacyMigration.agentLabel)"],
            timeout: 10
        )
    }

    static func disableLegacyAgent(uid: UInt32) -> Command {
        Command(
            executable: launchctlExecutable,
            arguments: ["bootout", "gui/\(uid)/\(LegacyMigration.agentLabel)"],
            timeout: 10
        )
    }
}
