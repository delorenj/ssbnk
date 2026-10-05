#if os(macOS)
import AppKit
import Combine
import Foundation
import ServiceManagement

enum LaunchAtLoginState: Equatable {
    case disabled
    case enabled
    case requiresApproval
}

protocol LaunchAtLoginControlling {
    var state: LaunchAtLoginState { get }
    func setEnabled(_ enabled: Bool) throws
}

final class ServiceManagementLaunchAtLoginController: LaunchAtLoginControlling {
    var state: LaunchAtLoginState {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound, .notRegistered: return .disabled
        @unknown default: return .disabled
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status == .notRegistered || SMAppService.mainApp.status == .notFound {
                try SMAppService.mainApp.register()
            }
        } else if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval {
            try SMAppService.mainApp.unregister()
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var configuration: ClientConfiguration
    @Published private(set) var queueSnapshot = TransferQueueSnapshot(
        queueDepth: 0,
        lastSuccessAt: nil,
        lastError: nil,
        isProcessing: false,
        pending: []
    )
    @Published private(set) var healthReport: HealthReport?
    @Published private(set) var isWorking = false
    @Published private(set) var activityMessage: String?
    @Published private(set) var launchAtLoginState: LaunchAtLoginState = .disabled
    @Published private(set) var legacyUploaderPresent = false
    @Published private(set) var startupError: String?
    @Published private(set) var syncError: String?

    private let configurationStore: ConfigurationStore
    private let launchAtLoginController: LaunchAtLoginControlling
    private var watchers: [String: CaptureDirectoryWatcher] = [:]
    private var clipboard: ClipboardCoordinator?
    let settingsWindow = SettingsWindowCoordinator()
    private let queue: TransferQueue?
    private let scanner: CaptureScanner?
    private let healthMonitor: HealthMonitor?
    private let legacyMigration: LegacyMigration
    private var retryTimer: Timer?
    private var transferTimer: Timer?
    private var directoryChangeTask: Task<Void, Never>?
    private var started = false
    private var configurationRevision = 0
    private var watcherActive = false
    private var watchedPath: String?
    private var watcherError: String?
    private var pendingScanMode: CaptureScanMode?
    private var pendingForce = false
    private var pendingLabel: String?

    init(
        runner: CommandRunning = ProcessCommandRunner(),
        publicHealthChecker: PublicHealthChecking = URLSessionPublicHealthChecker(),
        launchAtLoginController: LaunchAtLoginControlling = ServiceManagementLaunchAtLoginController(),
        fileManager: FileManager = .default
    ) {
        let supportDirectory = ApplicationPaths.supportDirectory(fileManager: fileManager)
        let store = ConfigurationStore(
            fileURL: supportDirectory.appendingPathComponent("configuration.json"),
            fileManager: fileManager
        )
        configurationStore = store
        self.launchAtLoginController = launchAtLoginController

        var initialError: String?
        do {
            configuration = try store.load() ?? .defaults()
        } catch {
            configuration = .defaults()
            initialError = "Could not read saved settings: \(error.localizedDescription)"
        }

        do {
            let queue = try TransferQueue(
                stateURL: supportDirectory.appendingPathComponent("sync-state.json"),
                outboxURL: supportDirectory.appendingPathComponent("Outbox", isDirectory: true),
                runner: runner,
                fileManager: fileManager
            )
            self.queue = queue
            clipboard = ClipboardCoordinator(queue: queue)
            scanner = CaptureScanner(queue: queue, fileManager: fileManager)
            healthMonitor = HealthMonitor(
                runner: runner,
                publicHealthChecker: publicHealthChecker,
                fileManager: fileManager,
                outboxURL: supportDirectory.appendingPathComponent("Outbox", isDirectory: true)
            )
        } catch {
            queue = nil
            scanner = nil
            healthMonitor = nil
            initialError = "Could not open the persistent outbox: \(error.localizedDescription)"
        }

        legacyMigration = LegacyMigration(runner: runner, fileManager: fileManager)
        launchAtLoginState = launchAtLoginController.state
        legacyUploaderPresent = legacyMigration.isPresent
        startupError = initialError
    }

    var launchAtLoginEnabled: Bool { launchAtLoginState != .disabled }

    var displayState: ClientHealthState {
        if watcherError != nil || startupError != nil || syncError != nil || !configuration.validationIssues().isEmpty {
            return .needsAttention
        }
        if isWorking { return .syncing }
        return healthReport?.state ?? .needsAttention
    }

    var attentionMessage: String? {
        watcherError ?? startupError ?? syncError ?? healthReport?.remedy ?? queueSnapshot.lastError
    }

    func start() {
        guard !started else { return }
        started = true
        if let queue {
            Task {
                await queue.setSnapshots { [weak self] snapshot in
                    Task { @MainActor in
                        guard let self else { return }
                        self.queueSnapshot = snapshot
                        for row in snapshot.history where row.phase == "ready" && row.copyConsumed != true {
                            await self.clipboard?.copy(id: row.id)
                        }
                    }
                }
            }
        }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.requestScan(mode: .automatic, force: false, label: nil) }
        }
        transferTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.advanceTransfers() }
        }
        requestScan(mode: .automatic, force: false, label: nil)
    }

    private func advanceTransfers() async {
        guard startupError == nil, let queue else { return }
        let legacy = await legacyMigration.detectPresence()
        let handedOver = await queue.hasCompletedHandover()
        guard !legacy || handedOver else { return }
        _ = await queue.process(configuration: configuration)
    }

    func testConnection() {
        guard !isWorking, let queue, let healthMonitor else { return }
        isWorking = true
        activityMessage = "Testing connection…"
        let configurationSnapshot = self.configuration
        let revision = configurationRevision
        Task {
            let snapshot = await queue.snapshot()
            let report = await healthMonitor.check(configuration: configurationSnapshot, queue: snapshot)
            if revision == configurationRevision {
                queueSnapshot = snapshot
                healthReport = report
                legacyUploaderPresent = await legacyMigration.detectPresence()
            }
            isWorking = false
            activityMessage = nil
            startPendingWorkIfNeeded()
        }
    }

    func syncNow() {
        requestScan(mode: .automatic, force: true, label: "Syncing new captures…")
    }

    func syncExisting() {
        requestScan(mode: .existing, force: true, label: "Syncing existing captures…")
    }

    func saveConfiguration(_ updated: ClientConfiguration) {
        do {
            try configurationStore.save(updated)
            configuration = updated
            configurationRevision += 1
            healthReport = nil
            startupError = nil
            syncError = nil
            stopWatcher()
            requestScan(mode: .automatic, force: false, label: nil)
        } catch {
            startupError = "Could not save settings: \(error.localizedDescription)"
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try launchAtLoginController.setEnabled(enabled)
            launchAtLoginState = launchAtLoginController.state
            if launchAtLoginState == .requiresApproval {
                startupError = "Approve SSBNK Client in System Settings → General → Login Items."
                if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            } else {
                startupError = nil
            }
        } catch {
            launchAtLoginState = launchAtLoginController.state
            startupError = "Could not update launch at login: \(error.localizedDescription)"
        }
    }

    func retireLegacyUploader(confirmed: Bool) {
        guard !isWorking, let queue, let healthMonitor else { return }
        isWorking = true
        activityMessage = "Verifying replacement…"
        let configurationSnapshot = self.configuration
        let revision = configurationRevision
        Task {
            let snapshot = await queue.snapshot()
            let report = await healthMonitor.check(configuration: configurationSnapshot, queue: snapshot)
            if revision == configurationRevision {
                queueSnapshot = snapshot
                healthReport = report
            }
            let freshState: ClientHealthState = revision == configurationRevision && watcherError == nil
                ? report.state
                : .needsAttention
            do {
                guard freshState == .healthy || (freshState == .syncing && report.inputs.publicHealthReachable && report.inputs.captureDirectoryAvailable && report.inputs.configurationValid && report.inputs.outboxAvailable) else { throw LegacyMigrationError.replacementNotHealthy }
                try await legacyMigration.cutover(configuration: configurationSnapshot, controlledReady: {
                    try await self.qualifyControlledCapture(configurationSnapshot)
                }, persistBoundary: {
                    try await queue.beginHandover()
                }, commitHandover: {
                    try await queue.markHandoverComplete()
                }, confirmed: confirmed)
                legacyUploaderPresent = await legacyMigration.detectPresence()
                startupError = nil
            } catch {
                startupError = error.localizedDescription
                legacyUploaderPresent = await legacyMigration.detectPresence()
            }
            isWorking = false
            activityMessage = nil
            startPendingWorkIfNeeded()
        }
    }

    private func qualifyControlledCapture(_ configuration: ClientConfiguration) async throws {
        let directory = ApplicationPaths.supportDirectory().appendingPathComponent("Handover Test")
        guard !directory.path.hasPrefix(configuration.screenshotURL.path + "/"), !directory.path.hasPrefix(configuration.recordingURL.path + "/") else { throw LegacyMigrationError.replacementNotHealthy }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent("controlled-\(UUID().uuidString).png")
        guard let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32), let data = image.representation(using: .png, properties: [:]) else { throw LegacyMigrationError.replacementNotHealthy }
        try data.write(to: path)
        guard let identity = CaptureIdentity.current(at: path) else { throw LegacyMigrationError.replacementNotHealthy }
        let credential = try await UploadCredentialProvider().resolve(reference: configuration.credentialReference ?? "")
        let transfer = QueuedTransfer(id: UUID(), identity: identity, kind: .image, sourcePath: path.path, stagedPath: path.path,
                                      createdAt: Date(), attempts: 0, nextAttemptAt: Date(), stagedSHA256: try CaptureHash.file(path),
                                      pinnedOrigin: configuration.resolvedOrigin, pinnedProfile: "original", autoCopy: false)
        let client = UploadClient()
        let deadline = Date().addingTimeInterval(180)
        var receipt = try await client.advance(transfer, credential: credential)
        while receipt.state != "ready" {
            guard Date() < deadline, receipt.state != "failed", receipt.state != "expired" else { throw LegacyMigrationError.replacementNotHealthy }
            try await Task.sleep(nanoseconds: 2_000_000_000)
            receipt = try await client.advance(transfer, credential: credential)
        }
        guard receipt.result?.sha256 == transfer.stagedSHA256, receipt.result?.availability == "available" else { throw LegacyMigrationError.replacementNotHealthy }
    }

    private func requestScan(mode: CaptureScanMode, force: Bool, label: String?) {
        if mode == .existing { pendingScanMode = .existing }
        else if pendingScanMode == nil { pendingScanMode = .automatic }
        pendingForce = pendingForce || force
        pendingLabel = label ?? pendingLabel
        startPendingWorkIfNeeded()
    }

    private func startPendingWorkIfNeeded() {
        guard !isWorking, pendingScanMode != nil else { return }
        isWorking = true
        Task { await drainPendingWork() }
    }

    private func drainPendingWork() async {
        guard let scanner, let queue, let healthMonitor else {
            isWorking = false
            return
        }

        while let mode = pendingScanMode {
            let force = pendingForce
            let label = pendingLabel
            pendingScanMode = nil
            pendingForce = false
            pendingLabel = nil
            activityMessage = label

            let configurationSnapshot = self.configuration
            let revision = configurationRevision
            let issues = configurationSnapshot.validationIssues()
            var cycleError: String?
            if issues.isEmpty {
                ensureWatcher(for: configurationSnapshot)
                do {
                    var roots: [URL: Set<MediaKind>] = [:]
                    roots[configurationSnapshot.screenshotURL, default: []].insert(.image)
                    roots[configurationSnapshot.recordingURL, default: []].insert(.video)
                    for (root, kinds) in roots {
                        do {
                            let scan = try await scanner.scan(directory: root, mode: mode, kinds: kinds)
                            if !scan.errors.isEmpty { cycleError = scan.errors.joined(separator: "\n") }
                        } catch { cycleError = "Capture root unavailable: \(root.path)" }
                    }
                    legacyUploaderPresent = await legacyMigration.detectPresence()
                    let handoverComplete = await queue.hasCompletedHandover()
                    let maySubmit = !legacyUploaderPresent || handoverComplete
                    let run = maySubmit ? await queue.process(configuration: configurationSnapshot, force: force) : TransferRunResult(blockedReason: "Legacy uploader detected; controlled handover required before automatic submission.")
                    if let blocked = run.blockedReason { cycleError = blocked }
                    if let persistenceError = run.persistenceError {
                        cycleError = [cycleError, persistenceError].compactMap { $0 }.joined(separator: "\n")
                    }
                } catch is CancellationError {
                    pendingScanMode = pendingScanMode ?? mode
                } catch {
                    cycleError = "Capture scan failed: \(error.localizedDescription)"
                }
            } else {
                stopWatcher()
            }

            let snapshot = await queue.snapshot()
            let report = await healthMonitor.check(configuration: configurationSnapshot, queue: snapshot)
            if revision == configurationRevision {
                queueSnapshot = snapshot
                healthReport = report
                syncError = cycleError
                legacyUploaderPresent = await legacyMigration.detectPresence()
            }
        }

        isWorking = false
        activityMessage = nil
        startPendingWorkIfNeeded()
    }

    func copyCapture(_ id: UUID) {
        Task {
            do {
                try await queue?.fenceCopies()
                try await queue?.refreshAvailability(id: id, reference: configuration.credentialReference ?? "")
                await clipboard?.copy(id: id, manual: true)
            } catch { try? await queue?.finishCopy(id: id, warning: "Availability could not be confirmed; Retry copy later.") }
        }
    }
    func retryCapture(_ id: UUID) {
        guard let queue, !legacyUploaderPresent else { return }
        Task { _ = await queue.process(configuration: configuration, force: true, only: id) }
    }
    func openCapture(_ row: QueuedTransfer) {
        guard let raw = row.receipt?.result?.url, let url = URL(string: raw) else { return }
        NSWorkspace.shared.open(url)
    }
    func showOptions() { settingsWindow.show(model: self) }

    private func ensureWatcher(for configuration: ClientConfiguration) {
        let roots = Set([configuration.screenshotURL, configuration.recordingURL])
        watcherError = nil
        for key in Array(watchers.keys) where !roots.contains(where: { $0.path == key }) { watchers.removeValue(forKey: key)?.stop() }
        for root in roots where watchers[root.path] == nil {
            let watcher = CaptureDirectoryWatcher()
            do {
                try watcher.start(directory: root,
                                  onChange: { [weak self] in Task { @MainActor in self?.scheduleDirectoryScan() } },
                                  onInvalidated: { [weak self] in Task { @MainActor in self?.watcherWasInvalidated() } })
                watchers[root.path] = watcher
            } catch { watcherError = "Capture root unavailable; other roots and staged transfers continue: \(root.path)" }
        }
        watcherActive = !watchers.isEmpty
    }
    private func stopWatcher() {
        for watcher in watchers.values { watcher.stop() }
        watchers.removeAll()
        watcherActive = false
        watchedPath = nil
    }

    private func watcherWasInvalidated() {
        stopWatcher()
        healthReport = nil
        watcherError = "The capture folder moved or became unavailable; SSBNK Client will retry."
        requestScan(mode: .automatic, force: false, label: nil)
    }

    private func scheduleDirectoryScan() {
        directoryChangeTask?.cancel()
        directoryChangeTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                self?.requestScan(mode: .automatic, force: false, label: nil)
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }
}
#endif
