import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum ClientHealthState: String, Equatable {
    case healthy = "Healthy", syncing = "Syncing", needsAttention = "Needs Attention"
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
protocol PublicHealthChecking { func check(_ url: URL) async -> PublicHealthResult }
protocol HTTPDataLoading { func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) }
final class URLSessionHTTPDataLoader: HTTPDataLoading {
    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, response)
    }
}
final class URLSessionPublicHealthChecker: PublicHealthChecking {
    private let loader: HTTPDataLoading
    init(session: URLSession = .shared) { loader = URLSessionHTTPDataLoader(session: session) }
    init(loader: HTTPDataLoading) { self.loader = loader }
    func check(_ url: URL) async -> PublicHealthResult {
        var request = URLRequest(url: url); request.timeoutInterval = 15
        do {
            let (data, response) = try await loader.data(for: request)
            guard response.statusCode == 200, data.count <= 65_536,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], object["status"] as? String == "ok"
            else { return PublicHealthResult(reachable: false, detail: "Health endpoint returned invalid or unhealthy status.") }
            return PublicHealthResult(reachable: true, detail: nil)
        } catch { return PublicHealthResult(reachable: false, detail: "Health endpoint unavailable.") }
    }
}
final class HealthMonitor {
    private let fileManager: FileManager
    private let outboxURL: URL
    private let now: () -> Date
    private let uploader: CaptureUploading
    private let credentials: UploadCredentialProviding
    init(runner: CommandRunning, publicHealthChecker: PublicHealthChecking = URLSessionPublicHealthChecker(),
         fileManager: FileManager = .default, outboxURL: URL, now: @escaping () -> Date = Date.init,
         uploader: CaptureUploading = UploadClient(), credentials: UploadCredentialProviding = UploadCredentialProvider()) {
        self.fileManager = fileManager; self.outboxURL = outboxURL; self.now = now
        self.uploader = uploader; self.credentials = credentials
    }
    func check(configuration: ClientConfiguration, queue: TransferQueueSnapshot) async -> HealthReport {
        let issues = configuration.validationIssues()
        var reachable = false
        var detail: String?
        if issues.isEmpty {
            do {
                let credential = try await credentials.resolve(reference: configuration.credentialReference ?? "")
                reachable = try await uploader.capabilities(origin: configuration.resolvedOrigin, credential: credential).processingReady
            } catch { detail = error.localizedDescription }
        }
        let imageAvailable = directoryIsUsable(configuration.screenshotURL)
        let videoAvailable = directoryIsUsable(configuration.recordingURL)
        let inputs = HealthInputs(configurationValid: issues.isEmpty,
                                  captureDirectoryAvailable: imageAvailable && videoAvailable,
                                  outboxAvailable: directoryIsUsable(outboxURL), publicHealthReachable: reachable,
                                  batchSSHAvailable: true, imageDirectoryWritable: imageAvailable, videoDirectoryWritable: videoAvailable,
                                  queueDepth: queue.queueDepth, isSyncing: queue.isProcessing, lastSyncError: queue.lastError)
        let remedy = issues.first?.description ?? (!imageAvailable ? "Screenshot folder unavailable; recordings and staged transfers continue." : !videoAvailable ? "Recording folder unavailable; screenshots and staged transfers continue." : !inputs.outboxAvailable ? "Allow access to private Application Support storage." : detail ?? queue.lastError)
        return HealthReport(state: Self.reduce(inputs), checkedAt: now(), inputs: inputs, remedy: remedy)
    }
    static func reduce(_ inputs: HealthInputs) -> ClientHealthState {
        guard inputs.configurationValid, inputs.captureDirectoryAvailable, inputs.outboxAvailable,
              inputs.publicHealthReachable, inputs.imageDirectoryWritable, inputs.videoDirectoryWritable,
              inputs.lastSyncError == nil else { return .needsAttention }
        return inputs.isSyncing || inputs.queueDepth > 0 ? .syncing : .healthy
    }
    private func directoryIsUsable(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue && fileManager.isReadableFile(atPath: url.path)
    }
}
