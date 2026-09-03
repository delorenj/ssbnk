import Foundation

enum LedgerDisposition: String, Codable, Equatable {
    case baselined
    case pending
    case delivered
}

struct LedgerEntry: Codable, Equatable {
    let identity: CaptureIdentity
    let kind: MediaKind
    let firstSeenAt: Date
    var disposition: LedgerDisposition
    var deliveredAt: Date?
}

struct QueuedTransfer: Codable, Equatable, Identifiable {
    let id: UUID
    let identity: CaptureIdentity
    let kind: MediaKind
    let sourcePath: String
    let stagedPath: String
    let createdAt: Date
    var attempts: Int
    var nextAttemptAt: Date
    var lastError: String?
}

struct PersistentQueueState: Codable, Equatable {
    static let currentVersion = 1

    var version = currentVersion
    var baselinedFolders: Set<String> = []
    var baselineSourcePaths: Set<String> = []
    var ledger: [String: LedgerEntry] = [:]
    var pending: [QueuedTransfer] = []
    var lastSuccessAt: Date?
    var lastError: String?

    private enum CodingKeys: String, CodingKey {
        case version, baselinedFolders, baselineSourcePaths, ledger, pending, lastSuccessAt, lastError
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        baselinedFolders = try container.decodeIfPresent(Set<String>.self, forKey: .baselinedFolders) ?? []
        baselineSourcePaths = try container.decodeIfPresent(Set<String>.self, forKey: .baselineSourcePaths) ?? []
        ledger = try container.decodeIfPresent([String: LedgerEntry].self, forKey: .ledger) ?? [:]
        pending = try container.decodeIfPresent([QueuedTransfer].self, forKey: .pending) ?? []
        lastSuccessAt = try container.decodeIfPresent(Date.self, forKey: .lastSuccessAt)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
    }
}

private struct TransferManifest: Codable {
    static let currentVersion = 1
    let version: Int
    let transfer: QueuedTransfer

    init(transfer: QueuedTransfer) {
        version = Self.currentVersion
        self.transfer = transfer
    }
}

struct TransferQueueSnapshot: Equatable {
    let queueDepth: Int
    let lastSuccessAt: Date?
    let lastError: String?
    let isProcessing: Bool
    let pending: [QueuedTransfer]
}

struct TransferRunResult: Equatable {
    var delivered = 0
    var failed = 0
    var blockedReason: String?
    var persistenceError: String?
}

enum TransferQueueError: Error, LocalizedError {
    case invalidStateVersion(Int)
    case sourceChanged(String)
    case stagedCopyChanged(String)
    case stagedCopyMissing(String)
    case transferFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidStateVersion(let version): return "Unsupported queue-state version \(version)."
        case .sourceChanged(let path): return "The source changed before it could be delivered: \(path)"
        case .stagedCopyChanged(let path): return "The queued copy changed before delivery: \(path)"
        case .stagedCopyMissing(let path): return "The queued copy is missing: \(path)"
        case .transferFailed(let message): return message
        }
    }
}

protocol QueueStatePersisting {
    func load(from url: URL) throws -> Data?
    func save(_ data: Data, to url: URL) throws
}

struct AtomicQueueStateStore: QueueStatePersisting {
    func load(from url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    func save(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
    }
}

actor TransferQueue {
    let stateURL: URL
    let outboxURL: URL

    private var state: PersistentQueueState
    private let runner: CommandRunning
    private let fileManager: FileManager
    private let stateStore: QueueStatePersisting
    private let now: () -> Date
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var processing = false
    private var volatileError: String?

    init(
        stateURL: URL,
        outboxURL: URL,
        runner: CommandRunning,
        fileManager: FileManager = .default,
        stateStore: QueueStatePersisting = AtomicQueueStateStore(),
        now: @escaping () -> Date = Date.init
    ) throws {
        self.stateURL = stateURL
        self.outboxURL = outboxURL
        self.runner = runner
        self.fileManager = fileManager
        self.stateStore = stateStore
        self.now = now

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        try fileManager.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outboxURL, withIntermediateDirectories: true)

        var loadedState = PersistentQueueState()
        if let data = try stateStore.load(from: stateURL) {
            do {
                loadedState = try decoder.decode(PersistentQueueState.self, from: data)
                guard loadedState.version == PersistentQueueState.currentVersion else {
                    throw TransferQueueError.invalidStateVersion(loadedState.version)
                }
            } catch {
                try Self.quarantineStateFile(stateURL, fileManager: fileManager, now: now())
                loadedState = PersistentQueueState()
            }
        }
        state = try Self.reconcileOutboxOnLaunch(
            loadedState,
            stateURL: stateURL,
            outboxURL: outboxURL,
            fileManager: fileManager,
            stateStore: stateStore,
            encoder: encoder,
            decoder: decoder
        )
    }

    func hasBaseline(for folder: String) -> Bool {
        state.baselinedFolders.contains(folder)
    }

    func establishBaseline(for folder: String, sourcePaths: [String], captures: [CaptureFile]) throws {
        guard !state.baselinedFolders.contains(folder) else { return }
        var candidate = state
        let timestamp = now()
        candidate.baselinedFolders.insert(folder)
        candidate.baselineSourcePaths.formUnion(sourcePaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        for capture in captures where candidate.ledger[capture.identity.key] == nil {
            candidate.ledger[capture.identity.key] = LedgerEntry(
                identity: capture.identity,
                kind: capture.kind,
                firstSeenAt: timestamp,
                disposition: .baselined
            )
        }
        try commit(candidate)
    }

    func shouldInspect(_ capture: CaptureFile, includeBaseline: Bool) -> Bool {
        let entry = state.ledger[capture.identity.key] ?? state.ledger.values.first {
            $0.identity.representsSameSourceVersion(as: capture.identity)
        }
        if let entry {
            return includeBaseline && entry.disposition == .baselined
        }
        if state.ledger.values.contains(where: {
            $0.disposition == .baselined && $0.identity.representsSameFile(as: capture.identity)
        }) {
            return includeBaseline
        }
        let hasIdentityForPath = state.ledger.values.contains { $0.identity.path == capture.identity.path }
        if !hasIdentityForPath && state.baselineSourcePaths.contains(capture.identity.path) {
            return includeBaseline
        }
        return true
    }

    @discardableResult
    func enqueue(_ capture: CaptureFile, includeBaseline: Bool = false) throws -> Bool {
        guard shouldInspect(capture, includeBaseline: includeBaseline) else { return false }
        guard capture.identity.matchesSource(at: capture.url, fileManager: fileManager) else {
            throw TransferQueueError.sourceChanged(capture.url.path)
        }

        let identifier = UUID()
        let itemDirectory = outboxURL.appendingPathComponent(identifier.uuidString, isDirectory: true)
        let stagedFile = itemDirectory.appendingPathComponent(capture.url.lastPathComponent)
        let temporaryFile = itemDirectory.appendingPathComponent(".stage-\(UUID().uuidString)")

        do {
            try fileManager.createDirectory(at: itemDirectory, withIntermediateDirectories: false)
            try fileManager.copyItem(at: capture.url, to: temporaryFile)
            try preserveCapturedModificationTime(capture.identity, at: temporaryFile)
            guard capture.identity.matchesSource(at: capture.url, fileManager: fileManager),
                  capture.identity.matchesStagedCopy(at: temporaryFile, fileManager: fileManager),
                  try filesHaveEqualBytes(capture.url, temporaryFile)
            else {
                throw TransferQueueError.stagedCopyChanged(temporaryFile.path)
            }
            try fileManager.moveItem(at: temporaryFile, to: stagedFile)

            let timestamp = now()
            let transfer = QueuedTransfer(
                id: identifier,
                identity: capture.identity,
                kind: capture.kind,
                sourcePath: capture.url.path,
                stagedPath: stagedFile.path,
                createdAt: timestamp,
                attempts: 0,
                nextAttemptAt: timestamp
            )
            try writeManifest(for: transfer)

            var candidate = state
            if includeBaseline {
                candidate.baselineSourcePaths.remove(capture.identity.path)
                candidate.ledger = candidate.ledger.filter { _, entry in
                    !(entry.disposition == .baselined && entry.identity.representsSameFile(as: capture.identity))
                }
            }
            candidate.pending.append(transfer)
            candidate.ledger[capture.identity.key] = LedgerEntry(
                identity: capture.identity,
                kind: capture.kind,
                firstSeenAt: candidate.ledger[capture.identity.key]?.firstSeenAt ?? timestamp,
                disposition: .pending
            )
            try commit(candidate)
            return true
        } catch {
            try? fileManager.removeItem(at: itemDirectory)
            throw error
        }
    }

    func snapshot() -> TransferQueueSnapshot {
        TransferQueueSnapshot(
            queueDepth: state.pending.count,
            lastSuccessAt: state.lastSuccessAt,
            lastError: volatileError ?? state.lastError,
            isProcessing: processing,
            pending: state.pending
        )
    }

    func disposition(for identity: CaptureIdentity) -> LedgerDisposition? {
        state.ledger[identity.key]?.disposition
    }

    func process(configuration: ClientConfiguration, force: Bool = false) async -> TransferRunResult {
        guard !processing else { return TransferRunResult() }
        let issues = configuration.validationIssues()
        guard issues.isEmpty else {
            let detail = "Fix client settings before syncing: \(issues.map(\.description).joined(separator: " "))"
            volatileError = detail
            return TransferRunResult(blockedReason: detail)
        }

        processing = true
        defer { processing = false }
        var runResult = TransferRunResult()

        while let transfer = nextDueTransfer(at: now(), force: force) {
            do {
                let recovered = try recoverStagedCopyIfNeeded(transfer)
                guard recovered.identity.matchesSource(at: URL(fileURLWithPath: recovered.sourcePath), fileManager: fileManager) else {
                    throw TransferQueueError.sourceChanged(recovered.sourcePath)
                }
                guard recovered.identity.matchesStagedCopy(at: URL(fileURLWithPath: recovered.stagedPath), fileManager: fileManager) else {
                    throw TransferQueueError.stagedCopyChanged(recovered.stagedPath)
                }
                guard try filesHaveEqualBytes(
                    URL(fileURLWithPath: recovered.sourcePath),
                    URL(fileURLWithPath: recovered.stagedPath)
                ) else {
                    throw TransferQueueError.stagedCopyChanged(recovered.stagedPath)
                }

                let result = try await runner.run(SSBNKCommands.rsync(
                    stagedFile: URL(fileURLWithPath: recovered.stagedPath),
                    destination: configuration.sshDestination,
                    remoteDirectory: configuration.remoteDirectory(for: recovered.kind)
                ))
                guard result.succeeded else {
                    let detail = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
                    throw TransferQueueError.transferFailed(
                        detail.isEmpty ? "rsync exited with status \(result.exitCode)" : detail
                    )
                }

                var candidate = state
                guard let index = candidate.pending.firstIndex(where: { $0.id == recovered.id }) else {
                    volatileError = "Queue state changed while delivering \(recovered.sourcePath)."
                    runResult.persistenceError = volatileError
                    break
                }
                let deliveredAt = now()
                candidate.pending.remove(at: index)
                var entry = candidate.ledger[recovered.identity.key] ?? LedgerEntry(
                    identity: recovered.identity,
                    kind: recovered.kind,
                    firstSeenAt: recovered.createdAt,
                    disposition: .pending
                )
                entry.disposition = .delivered
                entry.deliveredAt = deliveredAt
                candidate.ledger[recovered.identity.key] = entry
                candidate.lastSuccessAt = deliveredAt
                candidate.lastError = nil
                do {
                    try commit(candidate)
                    volatileError = nil
                } catch {
                    let detail = "rsync succeeded, but delivery state could not be saved: \(error.localizedDescription)"
                    volatileError = detail
                    runResult.persistenceError = detail
                    break
                }
                try? fileManager.removeItem(at: itemDirectory(for: recovered))
                runResult.delivered += 1
            } catch {
                var candidate = state
                guard let index = candidate.pending.firstIndex(where: { $0.id == transfer.id }) else {
                    volatileError = "Queue state changed while recording a retry for \(transfer.sourcePath)."
                    runResult.persistenceError = volatileError
                    break
                }
                var retry = candidate.pending[index]
                retry.attempts += 1
                retry.lastError = Self.concise(error.localizedDescription)
                retry.nextAttemptAt = now().addingTimeInterval(Self.retryDelay(afterAttempt: retry.attempts))
                candidate.pending[index] = retry
                candidate.lastError = retry.lastError
                do {
                    try writeManifest(for: retry)
                    try commit(candidate)
                    volatileError = nil
                    runResult.failed += 1
                } catch {
                    let detail = "Could not save retry state for \(retry.sourcePath): \(error.localizedDescription)"
                    volatileError = detail
                    runResult.persistenceError = detail
                }
                break
            }
        }
        return runResult
    }

    static func retryDelay(afterAttempt attempt: Int) -> TimeInterval {
        let exponent = min(max(attempt - 1, 0), 8)
        return min(300, 2 * pow(2, Double(exponent)))
    }

    private func nextDueTransfer(at date: Date, force: Bool) -> QueuedTransfer? {
        state.pending.filter { force || $0.nextAttemptAt <= date }.min { $0.createdAt < $1.createdAt }
    }

    private func recoverStagedCopyIfNeeded(_ transfer: QueuedTransfer) throws -> QueuedTransfer {
        let sourceURL = URL(fileURLWithPath: transfer.sourcePath)
        let stagedURL = URL(fileURLWithPath: transfer.stagedPath)
        guard transfer.identity.matchesSource(at: sourceURL, fileManager: fileManager) else {
            throw TransferQueueError.sourceChanged(transfer.sourcePath)
        }
        if fileManager.fileExists(atPath: stagedURL.path) {
            guard transfer.identity.matchesStagedCopy(at: stagedURL, fileManager: fileManager),
                  try filesHaveEqualBytes(sourceURL, stagedURL)
            else {
                throw TransferQueueError.stagedCopyChanged(stagedURL.path)
            }
            return transfer
        }
        let directory = stagedURL.deletingLastPathComponent()
        guard Self.isDescendant(directory, of: outboxURL) else {
            throw TransferQueueError.stagedCopyMissing(transfer.stagedPath)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".recover-\(UUID().uuidString)")
        do {
            try fileManager.copyItem(at: sourceURL, to: temporary)
            try preserveCapturedModificationTime(transfer.identity, at: temporary)
            guard transfer.identity.matchesSource(at: sourceURL, fileManager: fileManager),
                  transfer.identity.matchesStagedCopy(at: temporary, fileManager: fileManager),
                  try filesHaveEqualBytes(sourceURL, temporary)
            else {
                throw TransferQueueError.stagedCopyChanged(temporary.path)
            }
            try fileManager.moveItem(at: temporary, to: stagedURL)
            try writeManifest(for: transfer)
            return transfer
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    private static func reconcileOutboxOnLaunch(
        _ loadedState: PersistentQueueState,
        stateURL: URL,
        outboxURL: URL,
        fileManager: FileManager,
        stateStore: QueueStatePersisting,
        encoder: JSONEncoder,
        decoder: JSONDecoder
    ) throws -> PersistentQueueState {
        func expectedDirectory(for transfer: QueuedTransfer) -> URL {
            outboxURL.appendingPathComponent(transfer.id.uuidString, isDirectory: true)
        }

        func isValid(_ transfer: QueuedTransfer, in directory: URL? = nil) -> Bool {
            let sourcePath = URL(fileURLWithPath: transfer.sourcePath).standardizedFileURL.path
            let stagedURL = URL(fileURLWithPath: transfer.stagedPath).standardizedFileURL
            let itemDirectory = stagedURL.deletingLastPathComponent()
            guard transfer.identity.path == sourcePath,
                  itemDirectory == expectedDirectory(for: transfer).standardizedFileURL,
                  Self.isDescendant(stagedURL, of: outboxURL)
            else {
                return false
            }
            return directory == nil || directory?.standardizedFileURL == itemDirectory
        }

        func writeManifest(for transfer: QueuedTransfer) throws {
            let directory = expectedDirectory(for: transfer)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try encoder.encode(TransferManifest(transfer: transfer))
            try data.write(to: directory.appendingPathComponent("manifest.json"), options: [.atomic])
        }

        func quarantine(_ url: URL) throws {
            let quarantine = outboxURL.deletingLastPathComponent().appendingPathComponent(
                "Outbox Quarantine",
                isDirectory: true
            )
            try fileManager.createDirectory(at: quarantine, withIntermediateDirectories: true)
            try fileManager.moveItem(
                at: url,
                to: quarantine.appendingPathComponent("\(url.lastPathComponent)-\(UUID().uuidString)")
            )
        }

        var candidate = loadedState
        var validPending: [QueuedTransfer] = []
        for transfer in candidate.pending {
            guard isValid(transfer) else {
                if candidate.ledger[transfer.identity.key]?.disposition == .pending {
                    candidate.ledger.removeValue(forKey: transfer.identity.key)
                }
                candidate.lastError = "Rejected an unsafe or malformed queued transfer for \(transfer.sourcePath)."
                continue
            }
            validPending.append(transfer)
        }
        candidate.pending = validPending
        var knownIDs = Set(candidate.pending.map(\.id))
        for transfer in candidate.pending {
            if candidate.ledger[transfer.identity.key] == nil {
                candidate.ledger[transfer.identity.key] = LedgerEntry(
                    identity: transfer.identity,
                    kind: transfer.kind,
                    firstSeenAt: transfer.createdAt,
                    disposition: .pending
                )
            }
            try writeManifest(for: transfer)
        }

        let directories = try fileManager.contentsOfDirectory(
            at: outboxURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for directory in directories {
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                try quarantine(directory)
                continue
            }
            let manifestURL = directory.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? decoder.decode(TransferManifest.self, from: data),
                  manifest.version == TransferManifest.currentVersion,
                  isValid(manifest.transfer, in: directory)
            else {
                try quarantine(directory)
                continue
            }
            let transfer = manifest.transfer
            if candidate.ledger[transfer.identity.key]?.disposition == .delivered {
                try? fileManager.removeItem(at: directory)
                continue
            }
            if !knownIDs.contains(transfer.id) {
                candidate.pending.append(transfer)
                knownIDs.insert(transfer.id)
            }
            if candidate.ledger[transfer.identity.key] == nil {
                candidate.ledger[transfer.identity.key] = LedgerEntry(
                    identity: transfer.identity,
                    kind: transfer.kind,
                    firstSeenAt: transfer.createdAt,
                    disposition: .pending
                )
            }
        }
        let data = try encoder.encode(candidate)
        try stateStore.save(data, to: stateURL)
        return candidate
    }

    private func preserveCapturedModificationTime(_ identity: CaptureIdentity, at url: URL) throws {
        let date = Date(timeIntervalSince1970: Double(identity.modificationNanoseconds) / 1_000_000_000)
        try fileManager.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private func filesHaveEqualBytes(_ first: URL, _ second: URL) throws -> Bool {
        let firstHandle = try FileHandle(forReadingFrom: first)
        defer { try? firstHandle.close() }
        let secondHandle = try FileHandle(forReadingFrom: second)
        defer { try? secondHandle.close() }

        while true {
            let firstChunk = try firstHandle.read(upToCount: 1_048_576) ?? Data()
            let secondChunk = try secondHandle.read(upToCount: 1_048_576) ?? Data()
            guard firstChunk == secondChunk else { return false }
            if firstChunk.isEmpty { return true }
        }
    }

    private func commit(_ candidate: PersistentQueueState) throws {
        let data = try encoder.encode(candidate)
        try stateStore.save(data, to: stateURL)
        state = candidate
    }

    private func writeManifest(for transfer: QueuedTransfer) throws {
        let directory = itemDirectory(for: transfer)
        guard Self.isDescendant(directory, of: outboxURL) else {
            throw TransferQueueError.stagedCopyMissing(transfer.stagedPath)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(TransferManifest(transfer: transfer))
        try data.write(to: directory.appendingPathComponent("manifest.json"), options: [.atomic])
    }

    private func itemDirectory(for transfer: QueuedTransfer) -> URL {
        URL(fileURLWithPath: transfer.stagedPath).deletingLastPathComponent()
    }

    private static func quarantineStateFile(_ stateURL: URL, fileManager: FileManager, now: Date) throws {
        guard fileManager.fileExists(atPath: stateURL.path) else { return }
        let quarantine = stateURL.deletingLastPathComponent().appendingPathComponent(
            "sync-state.corrupt-\(Int(now.timeIntervalSince1970))-\(UUID().uuidString).json"
        )
        try fileManager.moveItem(at: stateURL, to: quarantine)
    }

    private static func isDescendant(_ child: URL, of parent: URL) -> Bool {
        let parentPath = parent.standardizedFileURL.path
        let childPath = child.standardizedFileURL.path
        return childPath == parentPath || childPath.hasPrefix(parentPath + "/")
    }

    private static func concise(_ message: String) -> String {
        String(message.replacingOccurrences(of: "\n", with: " ").prefix(500))
    }
}
