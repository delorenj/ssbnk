import Foundation
import Testing
@testable import SSBNKClient

@Suite(.serialized)
struct CaptureScannerTests {
    @Test
    func testClassifierMatchesWatcherFormatsAndIgnoresUnsupportedFiles() {
        for name in ["a.PNG", "b.jpg", "c.JPEG", "d.gif", "e.WEBP"] {
            XCTAssertEqual(CaptureClassifier.classify(URL(fileURLWithPath: name)), .image)
        }
        for name in ["a.MOV", "b.mp4", "c.AVI", "d.mkv", "e.WEBM", "f.flv", "g.WMV"] {
            XCTAssertEqual(CaptureClassifier.classify(URL(fileURLWithPath: name)), .video)
        }
        for name in ["notes.txt", "partial.png.tmp", ".DS_Store", "no-extension"] {
            XCTAssertNil(CaptureClassifier.classify(URL(fileURLWithPath: name)))
        }
    }

    @Test
    func testStableCheckerRejectsEmptyAndAcceptsUnchangedFile() async throws {
        let workspace = try TestWorkspace()
        let empty = try workspace.write("empty.png", contents: Data())
        let full = try workspace.write("full.png")
        let policy = StabilityPolicy(requiredUnchangedSamples: 1, maximumSamples: 1, intervalNanoseconds: 0)
        let checker = StableFileChecker(
            imagePolicy: policy,
            videoPolicy: policy,
            sleep: { _ in }
        )

        let emptyCapture = try await checker.stableCapture(at: empty, kind: .image)
        let fullCapture = try await checker.stableCapture(at: full, kind: .image)
        XCTAssertNil(emptyCapture)
        XCTAssertEqual(fullCapture?.identity.size, 7)
    }

    @Test
    func testFirstLaunchBaselinesExistingFilesAndQueuesNothing() async throws {
        let workspace = try TestWorkspace()
        _ = try workspace.write("old screenshot.png")
        _ = try workspace.write("old recording.mov")
        _ = try workspace.write("ignore.txt")
        let runner = RecordingCommandRunner()
        let queue = try TransferQueue(
            stateURL: workspace.stateURL,
            outboxURL: workspace.outboxURL,
            runner: runner
        )
        let scanner = CaptureScanner(queue: queue, stabilityChecker: ImmediateStableChecker())

        let first = try await scanner.scan(directory: workspace.captureDirectory)
        let second = try await scanner.scan(directory: workspace.captureDirectory)
        let snapshot = await queue.snapshot()

        XCTAssertEqual(first.baselined, 2)
        XCTAssertEqual(second.ignored, 2)
        XCTAssertEqual(snapshot.queueDepth, 0)
        XCTAssertTrue(runner.commands.isEmpty)
    }

    @Test
    func testNewMixedMediaWithSpacesAndUnicodeRoutesOnceAndKeepsOriginals() async throws {
        let workspace = try TestWorkspace()
        let runner = RecordingCommandRunner(results: [.success(.success), .success(.success)])
        let queue = try TransferQueue(
            stateURL: workspace.stateURL,
            outboxURL: workspace.outboxURL,
            runner: runner
        )
        let scanner = CaptureScanner(queue: queue, stabilityChecker: ImmediateStableChecker())
        _ = try await scanner.scan(directory: workspace.captureDirectory)

        let image = try workspace.write("Screen Shot ünicode 01.png")
        let video = try workspace.write("Screen Recording ünicode 01.MOV")
        _ = try workspace.write("unsupported capture.heic")

        let discovered = try await scanner.scan(directory: workspace.captureDirectory)
        let queued = await queue.snapshot()
        XCTAssertEqual(discovered.queued, 2)
        XCTAssertEqual(queued.queueDepth, 2)
        XCTAssertEqual(Set(queued.pending.map(\.kind)), Set([.image, .video]))
        XCTAssertEqual(Set(queued.pending.map { URL(fileURLWithPath: $0.stagedPath).lastPathComponent }), Set([
            image.lastPathComponent,
            video.lastPathComponent,
        ]))

        let run = await queue.process(configuration: configuration(captureDirectory: workspace.captureDirectory))
        let afterDelivery = await queue.snapshot()
        XCTAssertEqual(run.delivered, 2)
        XCTAssertEqual(afterDelivery.queueDepth, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: image.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: video.path))
        XCTAssertEqual(Set(runner.commands.map { $0.arguments.last! }), Set([
            "delorenj@big-chungus.burro-salmon.ts.net:/home/delorenj/Pictures/Screenshots/",
            "delorenj@big-chungus.burro-salmon.ts.net:/home/delorenj/Videos/Screencasts/",
        ]))

        _ = try await scanner.scan(directory: workspace.captureDirectory)
        _ = await queue.process(configuration: configuration(captureDirectory: workspace.captureDirectory), force: true)
        XCTAssertEqual(runner.commands.count, 2, "delivered captures must not replay")
    }

    @Test
    func testSyncExistingQueuesBaselineOnceAfterExplicitRequest() async throws {
        let workspace = try TestWorkspace()
        _ = try workspace.write("existing.png")
        let runner = RecordingCommandRunner(results: [.success(.success)])
        let queue = try TransferQueue(
            stateURL: workspace.stateURL,
            outboxURL: workspace.outboxURL,
            runner: runner
        )
        let scanner = CaptureScanner(queue: queue, stabilityChecker: ImmediateStableChecker())

        let baseline = try await scanner.scan(directory: workspace.captureDirectory)
        let firstExisting = try await scanner.scan(directory: workspace.captureDirectory, mode: .existing)
        let secondExisting = try await scanner.scan(directory: workspace.captureDirectory, mode: .existing)
        let pending = await queue.snapshot()
        XCTAssertEqual(baseline.baselined, 1)
        XCTAssertEqual(firstExisting.queued, 1)
        XCTAssertEqual(secondExisting.queued, 0)
        XCTAssertEqual(pending.queueDepth, 1)

        _ = await queue.process(configuration: configuration(captureDirectory: workspace.captureDirectory))
        let afterDelivery = try await scanner.scan(directory: workspace.captureDirectory, mode: .existing)
        XCTAssertEqual(afterDelivery.queued, 0)
        XCTAssertEqual(runner.commands.count, 1)
    }

    @Test
    func testCancellationAbortsStabilitySampling() async throws {
        let workspace = try TestWorkspace()
        let file = try workspace.write("cancel.png")
        let policy = StabilityPolicy(requiredUnchangedSamples: 1, maximumSamples: 2, intervalNanoseconds: 1)
        let checker = StableFileChecker(
            imagePolicy: policy,
            videoPolicy: policy,
            sleep: { _ in throw CancellationError() }
        )

        do {
            _ = try await checker.stableCapture(at: file, kind: .image)
            XCTFail("cancellation must escape the stability checker")
        } catch is CancellationError {
            // Expected.
        }
    }

    @Test
    func testDefaultVideoPolicyResetsAndRequiresSixNewUnchangedSamples() async throws {
        let url = URL(fileURLWithPath: "/tmp/recording.mov")
        let first = CaptureIdentity(path: url.path, size: 10, modificationNanoseconds: 1, fileNumber: 7)
        let changed = CaptureIdentity(path: url.path, size: 20, modificationNanoseconds: 2, fileNumber: 7)
        var snapshots = [first, changed, changed, changed, changed, changed, changed, changed]
        var sleepCount = 0
        let checker = StableFileChecker(
            snapshot: { _ in snapshots.removeFirst() },
            sleep: { _ in sleepCount += 1 }
        )

        let capture = try await checker.stableCapture(at: url, kind: .video)

        XCTAssertEqual(capture?.identity, changed)
        XCTAssertEqual(sleepCount, 7)
    }

    @Test
    func testPersistedBaselineSkipsPreexistingPathAfterQueueAndScannerRecreation() async throws {
        let workspace = try TestWorkspace()
        _ = try workspace.write("still here.png")
        let firstQueue = try TransferQueue(
            stateURL: workspace.stateURL,
            outboxURL: workspace.outboxURL,
            runner: RecordingCommandRunner()
        )
        let firstScanner = CaptureScanner(queue: firstQueue, stabilityChecker: ImmediateStableChecker())
        let initialBaseline = try await firstScanner.scan(directory: workspace.captureDirectory)
        XCTAssertEqual(initialBaseline.baselined, 1)

        let counter = CountingStabilityChecker()
        let resumedQueue = try TransferQueue(
            stateURL: workspace.stateURL,
            outboxURL: workspace.outboxURL,
            runner: RecordingCommandRunner()
        )
        let resumedScanner = CaptureScanner(queue: resumedQueue, stabilityChecker: counter)
        let result = try await resumedScanner.scan(directory: workspace.captureDirectory)
        let resumedSnapshot = await resumedQueue.snapshot()

        XCTAssertEqual(result.ignored, 1)
        XCTAssertEqual(counter.calls, 0, "known retained originals should bypass stability delays")
        XCTAssertEqual(resumedSnapshot.queueDepth, 0)
    }

    @Test
    func testDeliveredRetainedOriginalBypassesStabilityDelayOnLaterEvents() async throws {
        let workspace = try TestWorkspace()
        let runner = RecordingCommandRunner(results: [.success(.success)])
        let queue = try TransferQueue(
            stateURL: workspace.stateURL,
            outboxURL: workspace.outboxURL,
            runner: runner
        )
        let counter = CountingStabilityChecker()
        let scanner = CaptureScanner(queue: queue, stabilityChecker: counter)
        _ = try await scanner.scan(directory: workspace.captureDirectory)
        _ = try workspace.write("retained.png")
        _ = try await scanner.scan(directory: workspace.captureDirectory)
        XCTAssertEqual(counter.calls, 1)
        _ = await queue.process(configuration: configuration(captureDirectory: workspace.captureDirectory))

        _ = try await scanner.scan(directory: workspace.captureDirectory)

        XCTAssertEqual(counter.calls, 1)
    }

    @Test
    func testSyncExistingAsFirstScanQueuesStableCurrentFiles() async throws {
        let workspace = try TestWorkspace()
        _ = try workspace.write("history.png")
        let queue = try TransferQueue(
            stateURL: workspace.stateURL,
            outboxURL: workspace.outboxURL,
            runner: RecordingCommandRunner()
        )
        let scanner = CaptureScanner(queue: queue, stabilityChecker: ImmediateStableChecker())

        let result = try await scanner.scan(directory: workspace.captureDirectory, mode: .existing)
        let snapshot = await queue.snapshot()

        XCTAssertEqual(result.baselined, 1)
        XCTAssertEqual(result.queued, 1)
        XCTAssertEqual(snapshot.queueDepth, 1)
    }

    @Test
    func testUnstablePreexistingPathIsBaselinedWithoutDelayAndNeverAutoQueued() async throws {
        let workspace = try TestWorkspace()
        _ = try workspace.write("still-writing.mov")
        let checker = CountingStabilityChecker(alwaysUnstable: true)
        let queue = try TransferQueue(
            stateURL: workspace.stateURL,
            outboxURL: workspace.outboxURL,
            runner: RecordingCommandRunner()
        )
        let scanner = CaptureScanner(queue: queue, stabilityChecker: checker)

        let first = try await scanner.scan(directory: workspace.captureDirectory)
        let second = try await scanner.scan(directory: workspace.captureDirectory)
        let snapshot = await queue.snapshot()

        XCTAssertEqual(first.baselined, 1)
        XCTAssertEqual(second.ignored, 1)
        XCTAssertEqual(checker.calls, 0)
        XCTAssertEqual(snapshot.queueDepth, 0)
    }

    @Test
    func testScanContinuesAfterOneSourceDisappearsDuringStaging() async throws {
        let workspace = try TestWorkspace()
        let queue = try TransferQueue(
            stateURL: workspace.stateURL,
            outboxURL: workspace.outboxURL,
            runner: RecordingCommandRunner()
        )
        let baselineScanner = CaptureScanner(queue: queue, stabilityChecker: ImmediateStableChecker())
        _ = try await baselineScanner.scan(directory: workspace.captureDirectory)
        _ = try workspace.write("a-disappears.png")
        _ = try workspace.write("b-survives.png")
        let scanner = CaptureScanner(
            queue: queue,
            stabilityChecker: DisappearingStabilityChecker(filename: "a-disappears.png")
        )

        let result = try await scanner.scan(directory: workspace.captureDirectory)
        let snapshot = await queue.snapshot()

        XCTAssertEqual(result.failed, 1)
        XCTAssertEqual(result.queued, 1)
        XCTAssertEqual(result.errors.count, 1)
        XCTAssertTrue(result.errors[0].contains("a-disappears.png"))
        XCTAssertEqual(snapshot.queueDepth, 1)
        XCTAssertTrue(snapshot.pending[0].sourcePath.hasSuffix("b-survives.png"))
    }

    @Test
    func testExplicitlySyncedBaselineDoesNotHideAReplacementAtTheSamePath() async throws {
        let workspace = try TestWorkspace()
        let url = try workspace.write("reused.png", contents: Data("first".utf8))
        let queue = try TransferQueue(
            stateURL: workspace.stateURL,
            outboxURL: workspace.outboxURL,
            runner: RecordingCommandRunner(results: [.success(.success)])
        )
        let scanner = CaptureScanner(queue: queue, stabilityChecker: ImmediateStableChecker())

        _ = try await scanner.scan(directory: workspace.captureDirectory)
        _ = try await scanner.scan(directory: workspace.captureDirectory, mode: .existing)
        _ = await queue.process(configuration: configuration(captureDirectory: workspace.captureDirectory))

        try FileManager.default.removeItem(at: url)
        _ = try workspace.write("reused.png", contents: Data("second capture".utf8))
        let replacement = try await scanner.scan(directory: workspace.captureDirectory)
        let replacementSnapshot = await queue.snapshot()

        XCTAssertEqual(replacement.queued, 1)
        XCTAssertEqual(replacementSnapshot.queueDepth, 1)
    }
}

private final class CountingStabilityChecker: FileStabilityChecking {
    var calls = 0
    let alwaysUnstable: Bool

    init(alwaysUnstable: Bool = false) {
        self.alwaysUnstable = alwaysUnstable
    }

    func stableCapture(at url: URL, kind: MediaKind) async throws -> CaptureFile? {
        calls += 1
        if alwaysUnstable { return nil }
        return CaptureIdentity.current(at: url).map { CaptureFile(url: url, identity: $0, kind: kind) }
    }
}

private struct DisappearingStabilityChecker: FileStabilityChecking {
    let filename: String

    func stableCapture(at url: URL, kind: MediaKind) async throws -> CaptureFile? {
        guard let identity = CaptureIdentity.current(at: url) else { return nil }
        let capture = CaptureFile(url: url, identity: identity, kind: kind)
        if url.lastPathComponent == filename {
            try FileManager.default.removeItem(at: url)
        }
        return capture
    }
}
