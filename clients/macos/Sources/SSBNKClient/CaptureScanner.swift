import Foundation

struct CaptureIdentity: Codable, Equatable, Hashable {
    let path: String
    let size: UInt64
    let modificationNanoseconds: Int64
    let creationNanoseconds: Int64?
    let fileNumber: UInt64?

    init(
        path: String,
        size: UInt64,
        modificationNanoseconds: Int64,
        creationNanoseconds: Int64? = nil,
        fileNumber: UInt64? = nil
    ) {
        self.path = path
        self.size = size
        self.modificationNanoseconds = modificationNanoseconds
        self.creationNanoseconds = creationNanoseconds
        self.fileNumber = fileNumber
    }

    var key: String {
        "\(path)\u{1f}\(size)\u{1f}\(modificationNanoseconds)\u{1f}\(creationNanoseconds ?? -1)\u{1f}\(fileNumber ?? 0)"
    }

    static func current(at url: URL, fileManager: FileManager = .default) -> CaptureIdentity? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let fileType = attributes[.type] as? FileAttributeType,
              fileType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let modificationDate = attributes[.modificationDate] as? Date
        else {
            return nil
        }
        let creationDate = attributes[.creationDate] as? Date
        return CaptureIdentity(
            path: url.standardizedFileURL.path,
            size: size,
            modificationNanoseconds: Self.nanoseconds(modificationDate),
            creationNanoseconds: creationDate.map(Self.nanoseconds),
            fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        )
    }

    func matchesSource(at url: URL, fileManager: FileManager = .default) -> Bool {
        guard let current = Self.current(at: url, fileManager: fileManager),
              current.path == path,
              current.size == size,
              current.modificationNanoseconds == modificationNanoseconds
        else {
            return false
        }
        if let creationNanoseconds, let currentCreation = current.creationNanoseconds,
           creationNanoseconds != currentCreation { return false }
        if let fileNumber, let currentFileNumber = current.fileNumber,
           fileNumber != currentFileNumber { return false }
        return true
    }

    func matchesStagedCopy(at url: URL, fileManager: FileManager = .default) -> Bool {
        guard let current = Self.current(at: url, fileManager: fileManager) else { return false }
        // Filesystems exposed to macOS can round mtimes to a coarser resolution.
        // The queue also compares the source and staged bytes, so this tolerance
        // only prevents a metadata-resolution mismatch from rejecting a sound copy.
        let modificationDelta = abs(current.modificationNanoseconds - modificationNanoseconds)
        return current.size == size && modificationDelta <= 1_000_000_000
    }

    func representsSameSourceVersion(as other: CaptureIdentity) -> Bool {
        guard path == other.path,
              size == other.size,
              modificationNanoseconds == other.modificationNanoseconds
        else {
            return false
        }
        if let fileNumber, let otherFileNumber = other.fileNumber,
           fileNumber != otherFileNumber { return false }
        if let creationNanoseconds, let otherCreation = other.creationNanoseconds,
           abs(creationNanoseconds - otherCreation) > 1_000_000_000 { return false }
        return true
    }

    func representsSameFile(as other: CaptureIdentity) -> Bool {
        guard path == other.path else { return false }
        if let fileNumber, let otherFileNumber = other.fileNumber {
            return fileNumber == otherFileNumber
        }
        if let creationNanoseconds, let otherCreation = other.creationNanoseconds {
            return abs(creationNanoseconds - otherCreation) <= 1_000_000_000
        }
        return false
    }

    private static func nanoseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded(.down)) * 1_000_000
    }
}

struct CaptureFile: Equatable {
    let url: URL
    let identity: CaptureIdentity
    let kind: MediaKind
}

enum CaptureClassifier {
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]
    private static let videoExtensions: Set<String> = ["mp4", "avi", "mov", "mkv", "webm", "flv", "wmv"]

    static func classify(_ url: URL) -> MediaKind? {
        let fileExtension = url.pathExtension.lowercased()
        if imageExtensions.contains(fileExtension) { return .image }
        if videoExtensions.contains(fileExtension) { return .video }
        return nil
    }
}

struct StabilityPolicy: Equatable {
    let requiredUnchangedSamples: Int
    let maximumSamples: Int
    let intervalNanoseconds: UInt64

    static let image = StabilityPolicy(requiredUnchangedSamples: 1, maximumSamples: 10, intervalNanoseconds: 300_000_000)
    static let video = StabilityPolicy(requiredUnchangedSamples: 6, maximumSamples: 20, intervalNanoseconds: 500_000_000)
}

protocol FileStabilityChecking {
    func stableCapture(at url: URL, kind: MediaKind) async throws -> CaptureFile?
}

struct StableFileChecker: FileStabilityChecking {
    private let imagePolicy: StabilityPolicy
    private let videoPolicy: StabilityPolicy
    private let snapshot: (URL) -> CaptureIdentity?
    private let sleep: (UInt64) async throws -> Void

    init(
        fileManager: FileManager = .default,
        imagePolicy: StabilityPolicy = .image,
        videoPolicy: StabilityPolicy = .video,
        snapshot: ((URL) -> CaptureIdentity?)? = nil,
        sleep: @escaping (UInt64) async throws -> Void = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.imagePolicy = imagePolicy
        self.videoPolicy = videoPolicy
        self.snapshot = snapshot ?? { CaptureIdentity.current(at: $0, fileManager: fileManager) }
        self.sleep = sleep
    }

    func stableCapture(at url: URL, kind: MediaKind) async throws -> CaptureFile? {
        let policy = kind == .image ? imagePolicy : videoPolicy
        try Task.checkCancellation()
        guard var previous = snapshot(url), previous.size > 0 else { return nil }

        var unchanged = 0
        for _ in 0..<policy.maximumSamples {
            try await sleep(policy.intervalNanoseconds)
            try Task.checkCancellation()
            guard let current = snapshot(url), current.size > 0 else { return nil }
            if current.size == previous.size
                && current.modificationNanoseconds == previous.modificationNanoseconds
                && current.fileNumber == previous.fileNumber {
                unchanged += 1
                if unchanged >= policy.requiredUnchangedSamples {
                    return CaptureFile(url: url, identity: current, kind: kind)
                }
            } else {
                unchanged = 0
                previous = current
            }
        }
        return nil
    }
}

enum CaptureScanMode: Equatable {
    case automatic
    case existing
}

struct CaptureScanResult: Equatable {
    var baselined = 0
    var queued = 0
    var ignored = 0
    var unstable = 0
    var failed = 0
    var errors: [String] = []
}

actor CaptureScanner {
    private let queue: TransferQueue
    private let stabilityChecker: FileStabilityChecking
    private let fileManager: FileManager

    init(
        queue: TransferQueue,
        stabilityChecker: FileStabilityChecking = StableFileChecker(),
        fileManager: FileManager = .default
    ) {
        self.queue = queue
        self.stabilityChecker = stabilityChecker
        self.fileManager = fileManager
    }

    func scan(directory: URL, mode: CaptureScanMode = .automatic) async throws -> CaptureScanResult {
        let supportedFiles = try files(in: directory)
        let folderKey = directory.standardizedFileURL.path
        var result = CaptureScanResult()

        if !(await queue.hasBaseline(for: folderKey)) {
            let currentCaptures = supportedFiles.compactMap { url, kind -> CaptureFile? in
                guard let identity = CaptureIdentity.current(at: url, fileManager: fileManager) else { return nil }
                return CaptureFile(url: url, identity: identity, kind: kind)
            }
            try await queue.establishBaseline(
                for: folderKey,
                sourcePaths: supportedFiles.map { $0.0.standardizedFileURL.path },
                captures: currentCaptures
            )
            result.baselined = supportedFiles.count
            if mode == .automatic { return result }
        }

        let includeBaseline = mode == .existing
        for (url, kind) in supportedFiles {
            try Task.checkCancellation()
            guard let currentIdentity = CaptureIdentity.current(at: url, fileManager: fileManager) else {
                result.unstable += 1
                continue
            }
            let currentCapture = CaptureFile(url: url, identity: currentIdentity, kind: kind)
            guard await queue.shouldInspect(currentCapture, includeBaseline: includeBaseline) else {
                result.ignored += 1
                continue
            }
            guard let stable = try await stabilityChecker.stableCapture(at: url, kind: kind) else {
                result.unstable += 1
                continue
            }
            do {
                if try await queue.enqueue(stable, includeBaseline: includeBaseline) {
                    result.queued += 1
                } else {
                    result.ignored += 1
                }
            } catch {
                result.failed += 1
                result.errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return result
    }

    private func files(in directory: URL) throws -> [(URL, MediaKind)] {
        try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ).compactMap { url in
            guard let kind = CaptureClassifier.classify(url) else { return nil }
            return (url, kind)
        }.sorted { $0.0.lastPathComponent < $1.0.lastPathComponent }
    }
}

#if os(macOS)
import Darwin

final class CaptureDirectoryWatcher {
    private var source: DispatchSourceFileSystemObject?

    func start(
        directory: URL,
        onChange: @escaping () -> Void,
        onInvalidated: @escaping () -> Void
    ) throws {
        stop()
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .rename, .delete, .revoke],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler {
            let event = source.data
            if !event.intersection([.rename, .delete, .revoke]).isEmpty {
                onInvalidated()
            } else {
                onChange()
            }
        }
        source.setCancelHandler { close(descriptor) }
        self.source = source
        source.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    deinit { stop() }
}
#else
final class CaptureDirectoryWatcher {
    func start(directory: URL, onChange: @escaping () -> Void, onInvalidated: @escaping () -> Void) throws {}
    func stop() {}
}
#endif
