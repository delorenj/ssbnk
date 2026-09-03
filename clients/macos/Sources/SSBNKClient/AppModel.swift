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
    private let watcher = CaptureDirectoryWatcher()
    private let queue: TransferQueue?
    private let scanner: CaptureScanner?
    private let healthMonitor: HealthMonitor?
    private let legacyMigration: LegacyMigration
    private var retryTimer: Timer?
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
        retryTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.requestScan(mode: .automatic, force: false, label: nil) }
        }
        requestScan(mode: .automatic, force: false, label: nil)
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
        guard !isWorking else {
            startupError = "Wait for the current operation before saving settings."
            return
        }
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
                try await legacyMigration.retire(replacementHealth: freshState, confirmed: confirmed)
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
                    let scan = try await scanner.scan(directory: configurationSnapshot.captureURL, mode: mode)
                    if !scan.errors.isEmpty {
                        cycleError = scan.errors.joined(separator: "\n")
                    }
                    let run = await queue.process(configuration: configurationSnapshot, force: force)
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

    private func ensureWatcher(for configuration: ClientConfiguration) {
        let path = configuration.captureURL.standardizedFileURL.path
        if watcherActive, watchedPath == path { return }
        stopWatcher()
        do {
            try watcher.start(
                directory: configuration.captureURL,
                onChange: { [weak self] in
                    Task { @MainActor in self?.scheduleDirectoryScan() }
                },
                onInvalidated: { [weak self] in
                    Task { @MainActor in self?.watcherWasInvalidated() }
                }
            )
            watcherActive = true
            watchedPath = path
            watcherError = nil
        } catch {
            watcherActive = false
            watchedPath = nil
            watcherError = "Could not watch the capture folder; SSBNK Client will retry: \(error.localizedDescription)"
        }
    }

    private func stopWatcher() {
        watcher.stop()
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
