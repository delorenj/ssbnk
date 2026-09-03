import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum ClientHealthState: String, Equatable {
    case healthy = "Healthy"
    case syncing = "Syncing"
    case needsAttention = "Needs Attention"

    var systemImageName: String {
        switch self {
        case .healthy: return "checkmark.circle.fill"
        case .syncing: return "arrow.triangle.2.circlepath.circle.fill"
        case .needsAttention: return "exclamationmark.triangle.fill"
        }
    }
}

struct HealthInputs: Equatable {
    var configurationValid: Bool
    var captureDirectoryAvailable: Bool
    var outboxAvailable: Bool
    var publicHealthReachable: Bool
    var batchSSHAvailable: Bool
    var imageDirectoryWritable: Bool
    var videoDirectoryWritable: Bool
    var queueDepth: Int
    var isSyncing: Bool
    var lastSyncError: String?
}

struct HealthReport: Equatable {
    let state: ClientHealthState
    let checkedAt: Date
    let inputs: HealthInputs
    let remedy: String?
}

struct PublicHealthResult: Equatable {
    let reachable: Bool
    let detail: String?
}

protocol PublicHealthChecking {
    func check(_ url: URL) async -> PublicHealthResult
}

protocol HTTPDataLoading {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

final class URLSessionHTTPDataLoader: HTTPDataLoading {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, response)
    }
}

final class URLSessionPublicHealthChecker: PublicHealthChecking {
    private struct Payload: Decodable {
        let status: String
        let consistencyIssues: [String]?

        private enum CodingKeys: String, CodingKey {
            case status
            case consistencyIssues = "consistency_issues"
        }
    }

    private let loader: HTTPDataLoading

    init(session: URLSession = .shared) {
        loader = URLSessionHTTPDataLoader(session: session)
    }

    init(loader: HTTPDataLoading) {
        self.loader = loader
    }

    func check(_ url: URL) async -> PublicHealthResult {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await loader.data(for: request)
            guard (200...299).contains(response.statusCode) else {
                return PublicHealthResult(
                    reachable: false,
                    detail: "The health endpoint returned HTTP \(response.statusCode)."
                )
            }
            let payload: Payload
            do {
                payload = try JSONDecoder().decode(Payload.self, from: data)
            } catch {
                return PublicHealthResult(
                    reachable: false,
                    detail: "The health endpoint returned invalid JSON: \(error.localizedDescription)"
                )
            }
            guard payload.status == "ok" else {
                let issues = payload.consistencyIssues?.joined(separator: "; ")
                let suffix = issues.flatMap { $0.isEmpty ? nil : ": \($0)" } ?? ""
                return PublicHealthResult(
                    reachable: false,
                    detail: "The health endpoint reported \(payload.status)\(suffix)."
                )
            }
            return PublicHealthResult(reachable: true, detail: nil)
        } catch {
            return PublicHealthResult(reachable: false, detail: error.localizedDescription)
        }
    }
}

final class HealthMonitor {
    private let runner: CommandRunning
    private let publicHealthChecker: PublicHealthChecking
    private let fileManager: FileManager
    private let outboxURL: URL
    private let now: () -> Date

    init(
        runner: CommandRunning,
        publicHealthChecker: PublicHealthChecking = URLSessionPublicHealthChecker(),
        fileManager: FileManager = .default,
        outboxURL: URL,
        now: @escaping () -> Date = Date.init
    ) {
        self.runner = runner
        self.publicHealthChecker = publicHealthChecker
        self.fileManager = fileManager
        self.outboxURL = outboxURL
        self.now = now
    }

    func check(
        configuration: ClientConfiguration,
        queue: TransferQueueSnapshot
    ) async -> HealthReport {
        let configurationIssues = configuration.validationIssues()
        let captureAvailable = directoryIsUsable(configuration.captureURL)
        let outboxAvailable = directoryIsUsable(outboxURL)

        let publicHealth: PublicHealthResult
        if let healthURL = configuration.healthURL, configurationIssues.contains(.invalidPublicHealthURL) == false {
            publicHealth = await publicHealthChecker.check(healthURL)
        } else {
            publicHealth = PublicHealthResult(reachable: false, detail: ConfigurationIssue.invalidPublicHealthURL.description)
        }

        var sshAvailable = false
        var imageWritable = false
        var videoWritable = false
        var commandDetail: String?
        if configurationIssues.contains(.invalidSSHDestination) == false {
            do {
                let ssh = try await runner.run(SSBNKCommands.sshProbe(destination: configuration.sshDestination))
                sshAvailable = ssh.succeeded
                if !ssh.succeeded {
                    commandDetail = Self.commandFailure("Batch-mode SSH", result: ssh)
                }

                if sshAvailable && configurationIssues.contains(.invalidRemoteDirectory(.image)) == false {
                    let image = try await runner.run(SSBNKCommands.remoteWriteProbe(
                        destination: configuration.sshDestination,
                        directory: configuration.imageRemoteDirectory
                    ))
                    imageWritable = image.succeeded
                    if !image.succeeded {
                        commandDetail = Self.commandFailure("Screenshot directory check", result: image)
                    }
                }

                if sshAvailable && configurationIssues.contains(.invalidRemoteDirectory(.video)) == false {
                    let video = try await runner.run(SSBNKCommands.remoteWriteProbe(
                        destination: configuration.sshDestination,
                        directory: configuration.videoRemoteDirectory
                    ))
                    videoWritable = video.succeeded
                    if !video.succeeded && commandDetail == nil {
                        commandDetail = Self.commandFailure("Recording directory check", result: video)
                    }
                }
            } catch {
                commandDetail = error.localizedDescription
            }
        }

        let inputs = HealthInputs(
            configurationValid: configurationIssues.isEmpty,
            captureDirectoryAvailable: captureAvailable,
            outboxAvailable: outboxAvailable,
            publicHealthReachable: publicHealth.reachable,
            batchSSHAvailable: sshAvailable,
            imageDirectoryWritable: imageWritable,
            videoDirectoryWritable: videoWritable,
            queueDepth: queue.queueDepth,
            isSyncing: queue.isProcessing,
            lastSyncError: queue.lastError
        )
        return HealthReport(
            state: Self.reduce(inputs),
            checkedAt: now(),
            inputs: inputs,
            remedy: Self.remedy(
                inputs: inputs,
                configurationIssues: configurationIssues,
                publicDetail: publicHealth.detail,
                commandDetail: commandDetail
            )
        )
    }

    static func reduce(_ inputs: HealthInputs) -> ClientHealthState {
        let infrastructureReady = inputs.configurationValid
            && inputs.captureDirectoryAvailable
            && inputs.outboxAvailable
            && inputs.publicHealthReachable
            && inputs.batchSSHAvailable
            && inputs.imageDirectoryWritable
            && inputs.videoDirectoryWritable

        guard infrastructureReady, inputs.lastSyncError == nil else { return .needsAttention }
        if inputs.isSyncing || inputs.queueDepth > 0 { return .syncing }
        return .healthy
    }

    private func directoryIsUsable(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && fileManager.isReadableFile(atPath: url.path)
            && fileManager.isWritableFile(atPath: url.path)
    }

    private static func remedy(
        inputs: HealthInputs,
        configurationIssues: [ConfigurationIssue],
        publicDetail: String?,
        commandDetail: String?
    ) -> String? {
        if let issue = configurationIssues.first { return issue.description }
        if !inputs.captureDirectoryAvailable {
            return "Choose an existing, readable capture folder in Settings."
        }
        if !inputs.outboxAvailable {
            return "Allow SSBNK Client to write to its Application Support folder."
        }
        if !inputs.publicHealthReachable {
            return publicDetail ?? "Check the public SSBNK health URL and network connection."
        }
        if !inputs.batchSSHAvailable {
            return commandDetail ?? "Configure key-based SSH so BatchMode can connect without prompting."
        }
        if !inputs.imageDirectoryWritable {
            return commandDetail ?? "Grant the SSH account write access to the screenshot watch directory."
        }
        if !inputs.videoDirectoryWritable {
            return commandDetail ?? "Grant the SSH account write access to the recording watch directory."
        }
        if let error = inputs.lastSyncError { return error }
        return nil
    }

    private static func commandFailure(_ label: String, result: CommandResult) -> String {
        let detail = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.isEmpty { return "\(label) exited with status \(result.exitCode)." }
        return "\(label): \(String(detail.replacingOccurrences(of: "\n", with: " ").prefix(300)))"
    }
}
