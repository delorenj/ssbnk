import Foundation

enum LedgerDisposition: String, Codable, Equatable {
    case baselined, pending, delivered, legacyUnverified
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
    var stagedSHA256: String?
    var pinnedOrigin: String?
    var pinnedProfile: String?
    var phase: String?
    var offset: Int64?
    var receipt: UploadReceipt?
    var autoCopy: Bool?
    var copyConsumed: Bool?
    var copyWarning: String?
    var observedOrder: Int?
    var uploadProfile: String { pinnedProfile ?? (kind == .image ? "original" : "gif-30s-10fps-640") }
}

struct PersistentQueueState: Codable, Equatable {
    static let currentVersion = 2
    var version = currentVersion
    var baselinedFolders: Set<String> = []
    var baselineSourcePaths: Set<String> = []
    var ledger: [String: LedgerEntry] = [:]
    var pending: [QueuedTransfer] = []
    var lastSuccessAt: Date?
    var lastError: String?
    var history: [QueuedTransfer] = []
    var coverage: Set<String> = []
    var copyFence = 0
    var observedOrder = 0
    var handoverComplete = false
    var handoverBoundary: Date?
    var handoverRollbackRequired: Bool?

    private enum CodingKeys: String, CodingKey {
        case version, baselinedFolders, baselineSourcePaths, ledger, pending, lastSuccessAt, lastError
        case history, coverage, copyFence, observedOrder, handoverComplete, handoverBoundary, handoverRollbackRequired
    }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        guard version == 1 || version == 2 else { throw TransferQueueError.invalidStateVersion(version) }
        baselinedFolders = try c.decodeIfPresent(Set<String>.self, forKey: .baselinedFolders) ?? []
        baselineSourcePaths = try c.decodeIfPresent(Set<String>.self, forKey: .baselineSourcePaths) ?? []
        ledger = try c.decodeIfPresent([String: LedgerEntry].self, forKey: .ledger) ?? [:]
        pending = try c.decodeIfPresent([QueuedTransfer].self, forKey: .pending) ?? []
        history = try c.decodeIfPresent([QueuedTransfer].self, forKey: .history) ?? []
        coverage = try c.decodeIfPresent(Set<String>.self, forKey: .coverage) ?? []
        lastSuccessAt = try c.decodeIfPresent(Date.self, forKey: .lastSuccessAt)
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        copyFence = try c.decodeIfPresent(Int.self, forKey: .copyFence) ?? 0
        observedOrder = try c.decodeIfPresent(Int.self, forKey: .observedOrder) ?? 0
        handoverComplete = try c.decodeIfPresent(Bool.self, forKey: .handoverComplete) ?? false
        handoverBoundary = try c.decodeIfPresent(Date.self, forKey: .handoverBoundary)
        handoverRollbackRequired = try c.decodeIfPresent(Bool.self, forKey: .handoverRollbackRequired)
        if version == 1 {
            for key in ledger.keys where ledger[key]?.disposition == .delivered {
                ledger[key]?.disposition = .legacyUnverified
            }
            coverage = Set(baselinedFolders.flatMap { root in MediaKind.allCases.map { root + "\u{1f}" + $0.rawValue } })
            for index in pending.indices {
                observedOrder += 1
                pending[index].observedOrder = observedOrder
                pending[index].autoCopy = false
                pending[index].phase = "queued"
            }
            version = 2
        }
    }
}

struct TransferQueueSnapshot: Equatable {
    let queueDepth: Int
    let lastSuccessAt: Date?
    let lastError: String?
    let isProcessing: Bool
    let pending: [QueuedTransfer]
    var history: [QueuedTransfer] = []
}
struct TransferRunResult: Equatable {
    var delivered = 0
    var failed = 0
    var blockedReason: String?
    var persistenceError: String?
}
enum TransferQueueError: Error, LocalizedError {
    case invalidStateVersion(Int), sourceChanged(String), stagedCopyChanged(String), stagedCopyMissing(String), transferFailed(String)
    var errorDescription: String? {
        switch self {
        case .invalidStateVersion(let version): return "Unsupported queue-state version \(version); preserved for repair."
        case .sourceChanged(let path): return "The deferred source changed or disappeared: \(path)"
        case .stagedCopyChanged(let path): return "The verified staged bytes changed: \(path)"
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
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let handle = try FileHandle(forReadingFrom: url)
        try handle.synchronize(); try handle.close()
        try synchronizeDirectory(url.deletingLastPathComponent())
    }
}

actor TransferQueue {
    let stateURL: URL
    let outboxURL: URL
    private var state: PersistentQueueState
    private let fileManager: FileManager
    private let stateStore: QueueStatePersisting
    private let now: () -> Date
    private let encoder: JSONEncoder
    private let uploader: CaptureUploading
    private let credentials: UploadCredentialProviding
    private let stageBudget: UInt64
    private let freeFloor: UInt64
    private var processing = false
    private var volatileError: String?
    var snapshots: ((TransferQueueSnapshot) -> Void)?

    init(stateURL: URL, outboxURL: URL, runner: CommandRunning,
         fileManager: FileManager = .default, stateStore: QueueStatePersisting = AtomicQueueStateStore(),
         now: @escaping () -> Date = Date.init, uploader: CaptureUploading = UploadClient(),
         credentials: UploadCredentialProviding = UploadCredentialProvider(),
         stageBudget: UInt64 = 4 << 30, freeFloor: UInt64 = 512 << 20) throws {
        self.stateURL = stateURL; self.outboxURL = outboxURL; self.fileManager = fileManager
        self.stateStore = stateStore; self.now = now; self.uploader = uploader; self.credentials = credentials
        self.stageBudget = stageBudget; self.freeFloor = freeFloor
        encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        try fileManager.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileManager.createDirectory(at: outboxURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let data = try stateStore.load(from: stateURL) { state = try decoder.decode(PersistentQueueState.self, from: data) }
        else { state = PersistentQueueState() }
        for index in state.history.indices { state.history[index].copyConsumed = true }
        var recovered = state
        let directories = try fileManager.contentsOfDirectory(at: outboxURL, includingPropertiesForKeys: [.isDirectoryKey])
        let knownIDs = Set((recovered.pending + recovered.history).map(\.id))
        struct LegacyManifest: Decodable { let version: Int; let transfer: QueuedTransfer }
        for directory in directories {
            guard let id = UUID(uuidString: directory.lastPathComponent), !knownIDs.contains(id) else { continue }
            let manifestURL = directory.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL), data.count <= 65_536,
                  let manifest = try? decoder.decode(LegacyManifest.self, from: data), manifest.version == 1,
                  manifest.transfer.id == id else { continue }
            let transfer = manifest.transfer
            if recovered.ledger[transfer.identity.key]?.disposition == .delivered || recovered.ledger[transfer.identity.key]?.disposition == .legacyUnverified { continue }
            recovered.observedOrder += 1
            var pending = transfer
            pending.autoCopy = false; pending.phase = "queued"; pending.observedOrder = recovered.observedOrder
            recovered.pending.append(pending)
            recovered.ledger[transfer.identity.key] = LedgerEntry(identity: pending.identity, kind: pending.kind, firstSeenAt: pending.createdAt, disposition: .pending)
        }
        state = recovered
        let initialized = state
        let records = initialized.pending + initialized.history
        guard Set(records.map(\.id)).count == records.count,
              initialized.pending.allSatisfy({ initialized.ledger[$0.identity.key]?.disposition == .pending }) else {
            throw TransferQueueError.transferFailed("Queue ledger has duplicate UUIDs or inconsistent claims; preserved for repair.")
        }
        let expectedDirectories = Set(records.map { $0.id.uuidString })
        for path in try fileManager.contentsOfDirectory(at: outboxURL, includingPropertiesForKeys: [.isDirectoryKey]) {
            guard expectedDirectories.contains(path.lastPathComponent) else {
                throw TransferQueueError.transferFailed("Unclaimed outbox storage requires repair; stages were preserved.")
            }
        }
        for transfer in records {
            let expected = outboxURL.appendingPathComponent(transfer.id.uuidString).standardizedFileURL.path + "/"
            guard transfer.stagedPath.hasPrefix(expected), transfer.sourcePath == transfer.identity.path else {
                throw TransferQueueError.transferFailed("Unsafe queued paths; preserved for repair.")
            }
        }
        try stateStore.save(encoder.encode(state), to: stateURL)
    }

    func setSnapshots(_ callback: @escaping (TransferQueueSnapshot) -> Void) { snapshots = callback; callback(snapshot()) }
    func hasBaseline(for folder: String) -> Bool { state.baselinedFolders.contains(folder) }
    func hasCoverage(root: String, kind: MediaKind) -> Bool { state.coverage.contains(root + "\u{1f}" + kind.rawValue) }
    func establishBaseline(for folder: String, sourcePaths: [String], captures: [CaptureFile], kinds: Set<MediaKind> = Set(MediaKind.allCases)) throws {
        var candidate = state
        let timestamp = now()
        for kind in kinds {
            let key = folder + "\u{1f}" + kind.rawValue
            if candidate.coverage.contains(key) { continue }
            candidate.coverage.insert(key)
            for capture in captures where capture.kind == kind && candidate.ledger[capture.identity.key] == nil {
                candidate.ledger[capture.identity.key] = LedgerEntry(identity: capture.identity, kind: kind, firstSeenAt: timestamp, disposition: .baselined)
            }
        }
        candidate.baselinedFolders.insert(folder)
        try commit(candidate)
    }
    func shouldInspect(_ capture: CaptureFile, includeBaseline: Bool) -> Bool {
        if let entry = state.ledger[capture.identity.key] ?? state.ledger.values.first(where: { $0.identity.representsSameSourceVersion(as: capture.identity) }) {
            return includeBaseline && entry.disposition == .baselined
        }
        return true
    }
    @discardableResult
    func enqueue(_ capture: CaptureFile, includeBaseline: Bool = false) throws -> Bool {
        guard shouldInspect(capture, includeBaseline: includeBaseline) else { return false }
        guard capture.identity.matchesSource(at: capture.url, fileManager: fileManager) else { throw TransferQueueError.sourceChanged(capture.url.path) }
        var candidate = state
        candidate.observedOrder += 1
        let id = UUID(), timestamp = now()
        let staged = outboxURL.appendingPathComponent(id.uuidString).appendingPathComponent("capture")
        let transfer = QueuedTransfer(id: id, identity: capture.identity, kind: capture.kind, sourcePath: capture.url.path,
                                      stagedPath: staged.path, createdAt: timestamp, attempts: 0, nextAttemptAt: timestamp,
                                      phase: "deferred", autoCopy: !includeBaseline, observedOrder: candidate.observedOrder)
        candidate.pending.append(transfer)
        candidate.ledger[capture.identity.key] = LedgerEntry(identity: capture.identity, kind: capture.kind, firstSeenAt: timestamp, disposition: .pending)
        try commit(candidate)
        try stage(transfer)
        return true
    }
    private func stage(_ transfer: QueuedTransfer) throws {
        let maximum: UInt64 = transfer.kind == .image ? 50 << 20 : 1 << 30
        guard transfer.identity.size <= maximum else { throw TransferQueueError.transferFailed("Capture exceeds media input limit.") }
        var reserved: UInt64 = 0
        for item in state.pending + state.history {
            let directory = URL(fileURLWithPath: item.stagedPath).deletingLastPathComponent()
            let paths = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            for path in paths {
                let size = (try? fileManager.attributesOfItem(atPath: path.path)[.size] as? NSNumber)?.uint64Value ?? 0
                reserved += size
            }
        }
        let attributes = try fileManager.attributesOfFileSystem(forPath: outboxURL.path)
        let available = (attributes[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
        guard transfer.identity.size <= stageBudget, reserved <= stageBudget - transfer.identity.size,
              available >= transfer.identity.size + freeFloor else {
            try update(transfer.id) { $0.phase = "deferred"; $0.lastError = "Staging deferred: 4 GiB budget or free-space floor; existing transfers continue." }
            return
        }
        let source = URL(fileURLWithPath: transfer.sourcePath), staged = URL(fileURLWithPath: transfer.stagedPath)
        guard transfer.identity.matchesSource(at: source, fileManager: fileManager) else { throw TransferQueueError.sourceChanged(source.path) }
        try fileManager.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temp = staged.deletingLastPathComponent().appendingPathComponent(".stage")
        try? fileManager.removeItem(at: temp)
        defer { try? fileManager.removeItem(at: temp) }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard fileManager.createFile(atPath: temp.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw TransferQueueError.transferFailed("Could not reserve private stage.") }
        let output = try FileHandle(forWritingTo: temp)
        defer { try? output.close() }
        var written: UInt64 = 0
        while let data = try input.read(upToCount: Int(min(1_048_576, transfer.identity.size - written + 1))), !data.isEmpty {
            guard UInt64(data.count) <= transfer.identity.size - written else { throw TransferQueueError.sourceChanged(source.path) }
            try output.write(contentsOf: data)
            written += UInt64(data.count)
        }
        guard written == transfer.identity.size else { throw TransferQueueError.sourceChanged(source.path) }
        try output.synchronize()
        try output.close()
        let digest = try CaptureHash.file(temp)
        if let expected = transfer.stagedSHA256, digest != expected { throw TransferQueueError.stagedCopyChanged(temp.path) }
        guard transfer.identity.matchesSource(at: source, fileManager: fileManager), try CaptureHash.file(source) == digest else { throw TransferQueueError.sourceChanged(source.path) }
        let handle = try FileHandle(forReadingFrom: temp); try handle.synchronize(); try handle.close()
        try? fileManager.removeItem(at: staged)
        try fileManager.moveItem(at: temp, to: staged)
        try synchronizeDirectory(staged.deletingLastPathComponent())
        try synchronizeDirectory(outboxURL)
        try update(transfer.id) { $0.stagedSHA256 = digest; $0.phase = "queued"; $0.lastError = nil }
    }
    func reconcileDeferred() throws {
        for transfer in state.pending where transfer.phase == "deferred" {
            do { try stage(transfer) }
            catch { try update(transfer.id) { $0.phase = "error"; $0.lastError = error.localizedDescription } }
        }
    }
    func snapshot() -> TransferQueueSnapshot {
        let rows = (state.pending + state.history).sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            if $0.observedOrder != $1.observedOrder { return ($0.observedOrder ?? 0) > ($1.observedOrder ?? 0) }
            return $0.id.uuidString > $1.id.uuidString
        }
        return TransferQueueSnapshot(queueDepth: state.pending.count, lastSuccessAt: state.lastSuccessAt,
                                     lastError: volatileError ?? state.lastError, isProcessing: processing,
                                     pending: state.pending, history: rows)
    }
    func disposition(for identity: CaptureIdentity) -> LedgerDisposition? { state.ledger[identity.key]?.disposition }
    func process(configuration: ClientConfiguration, force: Bool = false, only: UUID? = nil) async -> TransferRunResult {
        guard !processing else { return TransferRunResult() }
        guard configuration.validationIssues().isEmpty else { return TransferRunResult(blockedReason: "Fix API origin and vault settings before delivery.") }
        processing = true; snapshots?(snapshot())
        defer { processing = false; snapshots?(snapshot()) }
        var result = TransferRunResult()
        do { try reconcileDeferred() } catch { result.persistenceError = error.localizedDescription; return result }
        let due = state.pending.filter { (only == nil || $0.id == only) && $0.phase != "deferred" && ($0.phase != "error" || force) && (force || $0.nextAttemptAt <= now()) }
        for original in due {
            do {
                var transfer = original.receipt?.acceptedAt != nil ? original : try verifiedTransfer(original)
                if transfer.pinnedOrigin == nil {
                    try update(transfer.id) { $0.pinnedOrigin = configuration.resolvedOrigin; $0.pinnedProfile = $0.uploadProfile }
                    transfer = state.pending.first { $0.id == transfer.id }!
                }
                try update(transfer.id) { $0.phase = "uploading" }
                let credential = try await credentials.resolve(reference: configuration.credentialReference ?? "")
                let receipt: UploadReceipt
                if force, transfer.receipt?.state == "failed", transfer.receipt?.error?.retryable == true {
                    receipt = try await uploader.retry(transfer, credential: credential)
                } else { receipt = try await uploader.advance(transfer, credential: credential) }
                var candidate = state
                _ = try receipt.parsed(for: transfer)
                guard let index = candidate.pending.firstIndex(where: { $0.id == transfer.id }) else { throw TransferQueueError.transferFailed("Queue changed during upload.") }
                candidate.pending[index].receipt = receipt; candidate.pending[index].offset = receipt.offset
                candidate.pending[index].phase = receipt.state == "receiving" ? "queued" : receipt.state == "failed" ? "error" : receipt.state
                candidate.pending[index].lastError = receipt.error?.message
                candidate.pending[index].nextAttemptAt = now().addingTimeInterval(["verifying", "queued", "processing"].contains(receipt.state) ? 2 : 0)
                if receipt.state == "ready" {
                    var ready = candidate.pending.remove(at: index)
                    ready.phase = "ready"
                    candidate.history.append(ready)
                    candidate.ledger[transfer.identity.key]?.disposition = .delivered
                    candidate.ledger[transfer.identity.key]?.deliveredAt = now()
                    candidate.lastSuccessAt = now(); candidate.lastError = nil
                    result.delivered += 1
                }
                try commit(candidate)
                if receipt.state == "ready" { try? fileManager.removeItem(at: URL(fileURLWithPath: transfer.stagedPath).deletingLastPathComponent()) }
            } catch {
                let failure = error as? UploadFailure
                do {
                    try update(original.id) {
                        $0.attempts += 1; $0.lastError = error.localizedDescription
                        $0.phase = failure?.retryable == true ? "queued" : "error"
                        $0.nextAttemptAt = now().addingTimeInterval(Self.retryDelay(afterAttempt: $0.attempts))
                    }
                    result.failed += 1
                } catch { volatileError = "Could not persist upload transition: \(error.localizedDescription)"; result.persistenceError = volatileError; break }
            }
        }
        return result
    }
    static func retryDelay(afterAttempt attempt: Int) -> TimeInterval { min(30, 2 * pow(2, Double(min(max(attempt - 1, 0), 4)))) }
    private func verifiedTransfer(_ transfer: QueuedTransfer) throws -> QueuedTransfer {
        let staged = URL(fileURLWithPath: transfer.stagedPath)
        if fileManager.fileExists(atPath: staged.path) {
            let digest = try CaptureHash.file(staged)
            if let expected = transfer.stagedSHA256 {
                guard digest == expected, (try fileManager.attributesOfItem(atPath: staged.path)[.size] as? NSNumber)?.uint64Value == transfer.identity.size else { throw TransferQueueError.stagedCopyChanged(staged.path) }
                return transfer
            }
            guard transfer.identity.matchesSource(at: URL(fileURLWithPath: transfer.sourcePath)), try CaptureHash.file(URL(fileURLWithPath: transfer.sourcePath)) == digest else { throw TransferQueueError.stagedCopyChanged(staged.path) }
            try update(transfer.id) { $0.stagedSHA256 = digest }
        } else { try stage(transfer) }
        guard let recovered = state.pending.first(where: { $0.id == transfer.id }), recovered.phase != "deferred" else { throw TransferQueueError.stagedCopyMissing(staged.path) }
        return recovered
    }
    func claimCopy(id: UUID, manual: Bool = false) throws -> QueuedTransfer? {
        guard let index = state.history.firstIndex(where: { $0.id == id }), state.history[index].receipt?.result?.availability == "available" else { return nil }
        let transfer = state.history[index], order = transfer.observedOrder ?? 0
        let newestEligible = (state.pending + state.history).filter { $0.autoCopy == true }.map { $0.observedOrder ?? 0 }.max() ?? 0
        guard manual || (transfer.autoCopy == true && transfer.copyConsumed != true && order >= max(state.copyFence, newestEligible)) else { return nil }
        var candidate = state
        candidate.copyFence = max(candidate.copyFence, manual ? candidate.observedOrder : newestEligible)
        candidate.history[index].copyConsumed = true
        candidate.history[index].copyWarning = "Copy acknowledgement unknown; Retry copy is available."
        try commit(candidate)
        return state.history[index]
    }
    func fenceCopies() throws {
        var candidate = state
        candidate.copyFence = max(candidate.copyFence, candidate.observedOrder)
        for index in candidate.history.indices where (candidate.history[index].observedOrder ?? 0) <= candidate.copyFence {
            candidate.history[index].copyConsumed = true
        }
        try commit(candidate)
    }
    func refreshAvailability(id: UUID, reference: String) async throws {
        guard let row = state.history.first(where: { $0.id == id }), row.receipt?.result?.availability == "available" else { return }
        let credential = try await credentials.resolve(reference: reference)
        let current = try await uploader.advance(row, credential: credential)
        var candidate = state
        guard let index = candidate.history.firstIndex(where: { $0.id == id }) else { return }
        candidate.history[index].receipt = try current.parsed(for: row)
        try commit(candidate)
    }
    func finishCopy(id: UUID, warning: String?) throws {
        var candidate = state
        guard let index = candidate.history.firstIndex(where: { $0.id == id }) else { return }
        candidate.history[index].copyWarning = warning
        try commit(candidate)
    }
    func beginHandover() throws { var candidate = state; candidate.handoverBoundary = now(); candidate.handoverRollbackRequired = true; try commit(candidate) }
    func markHandoverComplete() throws { var candidate = state; candidate.handoverComplete = true; candidate.handoverRollbackRequired = false; try commit(candidate) }
    func hasCompletedHandover() -> Bool { state.handoverComplete }
    private func update(_ id: UUID, change: (inout QueuedTransfer) -> Void) throws {
        var candidate = state
        guard let index = candidate.pending.firstIndex(where: { $0.id == id }) else { return }
        change(&candidate.pending[index]); try commit(candidate)
    }
    private func commit(_ candidate: PersistentQueueState) throws {
        try stateStore.save(encoder.encode(candidate), to: stateURL)
        state = candidate; snapshots?(snapshot())
    }
}
