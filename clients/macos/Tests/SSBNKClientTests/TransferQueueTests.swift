import Foundation
import Testing
@testable import SSBNKClient

@Suite(.serialized)
struct TransferQueueTests {
    @Test
    func testPendingQueueRecoversAfterRestartAndRestagesFromPreservedOriginal() async throws {
        let workspace = try TestWorkspace()
        let source = try workspace.write("recover me.png")
        let firstRunner = RecordingCommandRunner()
        var queue: TransferQueue? = try TransferQueue(
            stateURL: workspace.stateURL,
            outboxURL: workspace.outboxURL,
            runner: firstRunner
        )
        let capture = try await captureFile(at: source, kind: .image)
        let wasEnqueued = try await queue?.enqueue(capture)
        let firstSnapshot = await queue?.snapshot()
        XCTAssertTrue(wasEnqueued == true)
        let originalPending = try XCTUnwrap(firstSnapshot?.pending.first)
        try FileManager.default.removeItem(at: URL(fileURLWithPath: originalPending.stagedPath))
        queue = nil

        let resumedRunner = RecordingCommandRunner(results: [.success(.success)])
        let resumed = try TransferQueue(
            stateURL: workspace.stateURL,
            outboxURL: workspace.outboxURL,
            runner: resumedRunner
        )
        let resumedSnapshot = await resumed.snapshot()
        XCTAssertEqual(resumedSnapshot.queueDepth, 1)

        let result = await resumed.process(configuration: configuration(captureDirectory: workspace.captureDirectory))
        let deliveredSnapshot = await resumed.snapshot()
        let deliveredDisposition = await resumed.disposition(for: capture.identity)
        XCTAssertEqual(result.delivered, 1)
        XCTAssertEqual(deliveredSnapshot.queueDepth, 0)
        XCTAssertEqual(deliveredDisposition, .delivered)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))

        let afterSecondRestart = try TransferQueue(
            stateURL: workspace.stateURL,
            outboxURL: workspace.outboxURL,
            runner: RecordingCommandRunner()
        )
        let secondRestartSnapshot = await afterSecondRestart.snapshot()
        let secondRestartDisposition = await afterSecondRestart.disposition(for: capture.identity)
        XCTAssertEqual(secondRestartSnapshot.queueDepth, 0)
        XCTAssertEqual(secondRestartDisposition, .delivered)
    }

    @Test
    func testFailureUsesBoundedBackoffAndRetriesOnlyWhenDue() async throws {
        let workspace = try TestWorkspace()
        let source = try workspace.write("offline.mov")
        let clock = TestClock()
        let runner = RecordingCommandRunner(results: [
            .success(.failure("network unavailable")),
            .success(.success),
        ])
        let queue = try TransferQueue(
            stateURL: workspace.stateURL,
            outboxURL: workspace.outboxURL,
            runner: runner,
            now: clock.now
        )
        let capture = try await captureFile(at: source, kind: .video)
        try await queue.enqueue(capture)

        let failed = await queue.process(configuration: configuration(captureDirectory: workspace.captureDirectory))
        let afterFailure = await queue.snapshot()
        XCTAssertEqual(failed.failed, 1)
        XCTAssertEqual(afterFailure.pending.first?.attempts, 1)
        XCTAssertEqual(afterFailure.pending.first?.nextAttemptAt, clock.date.addingTimeInterval(2))
        XCTAssertEqual(afterFailure.lastError, "network unavailable")

        let tooEarly = await queue.process(configuration: configuration(captureDirectory: workspace.captureDirectory))
        XCTAssertEqual(tooEarly, TransferRunResult())
        XCTAssertEqual(runner.commands.count, 1)

        clock.advance(3)
        let recovered = await queue.process(configuration: configuration(captureDirectory: workspace.captureDirectory))
        let recoveredSnapshot = await queue.snapshot()
        XCTAssertEqual(recovered.delivered, 1)
        XCTAssertEqual(recoveredSnapshot.queueDepth, 0)
        XCTAssertNil(recoveredSnapshot.lastError)
        XCTAssertEqual(runner.commands.count, 2)

        XCTAssertEqual(TransferQueue.retryDelay(afterAttempt: 1), 2)
        XCTAssertEqual(TransferQueue.retryDelay(afterAttempt: 2), 4)
        XCTAssertEqual(TransferQueue.retryDelay(afterAttempt: 100), 300)
    }

    @Test
    func testRsyncSuccessThenStateWriteFailureIsTransactionalAndDoesNotCorruptIndex() async throws {
        let workspace = try TestWorkspace()
        let source = try workspace.write("persist-failure.png")
        let store = ConditionalQueueStateStore { data in
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            return object?["lastSuccessAt"] != nil
        }
        let runner = RecordingCommandRunner(results: [.success(.success)])
        let queue = try TransferQueue(
            stateURL: workspace.stateURL,
            outboxURL: workspace.outboxURL,
            runner: runner,
            stateStore: store
        )
        let capture = try await captureFile(at: source, kind: .image)
        try await queue.enqueue(capture)

        let result = await queue.process(configuration: configuration(captureDirectory: workspace.captureDirectory))
        let snapshot = await queue.snapshot()

        XCTAssertEqual(result.delivered, 0)
        XCTAssertNotNil(result.persistenceError)
        XCTAssertTrue(result.persistenceError?.contains("rsync succeeded") == true)
        XCTAssertEqual(snapshot.queueDepth, 1)
        XCTAssertEqual(snapshot.pending[0].id, snapshot.pending.first?.id)
        XCTAssertTrue(snapshot.lastError?.contains("could not be saved") == true)
        XCTAssertEqual(runner.commands.count, 1)
    }

    @Test
    func testRetryStatePersistenceFailureIsActionable() async throws {
        let workspace = try TestWorkspace()
        let source = try workspace.write("retry-persist.mov")
        let store = ConditionalQueueStateStore { data in
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pending = object["pending"] as? [[String: Any]],
                  let attempts = pending.first?["attempts"] as? Int
            else { return false }
            return attempts > 0
        }
        let queue = try TransferQueue(
            stateURL: workspace.stateURL,
            outboxURL: workspace.outboxURL,
            runner: RecordingCommandRunner(results: [.success(.failure())]),
            stateStore: store
        )
        try await queue.enqueue(try await captureFile(at: source, kind: .video))

        let result = await queue.process(configuration: configuration(captureDirectory: workspace.captureDirectory))
        let snapshot = await queue.snapshot()

        XCTAssertNotNil(result.persistenceError)
        XCTAssertTrue(snapshot.lastError?.contains("Could not save retry state") == true)
        XCTAssertEqual(snapshot.queueDepth, 1)
        XCTAssertEqual(snapshot.pending[0].attempts, 0, "failed persistence must not partially mutate memory")
    }

    @Test
    func testFutureStateIsQuarantinedAndPendingManifestIsRecoveredWithLedger() async throws {
        let workspace = try TestWorkspace()
        let source = try workspace.write("future-state.png")
        let first = try TransferQueue(
            stateURL: workspace.stateURL,
            outboxURL: workspace.outboxURL,
            runner: RecordingCommandRunner()
        )
        let capture = try await captureFile(at: source, kind: .image)
        try await first.enqueue(capture)
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: workspace.stateURL)) as? [String: Any])
        object["version"] = 999
        try JSONSerialization.data(withJSONObject: object).write(to: workspace.stateURL, options: [.atomic])

        let recovered = try TransferQueue(
            stateURL: workspace.stateURL,
            outboxURL: workspace.outboxURL,
            runner: RecordingCommandRunner()
        )
        let snapshot = await recovered.snapshot()
        let disposition = await recovered.disposition(for: capture.identity)
        let stateFiles = try FileManager.default.contentsOfDirectory(atPath: workspace.stateURL.deletingLastPathComponent().path)

        XCTAssertEqual(snapshot.queueDepth, 1)
        XCTAssertEqual(disposition, .pending)
        XCTAssertTrue(stateFiles.contains { $0.hasPrefix("sync-state.corrupt-") })
    }

    @Test
    func testTruncatedStateIsQuarantinedAndPendingManifestIsRecovered() async throws {
        let workspace = try TestWorkspace()
        let source = try workspace.write("truncated-state.png")
        let first = try TransferQueue(
            stateURL: workspace.stateURL,
            outboxURL: workspace.outboxURL,
            runner: RecordingCommandRunner()
        )
        try await first.enqueue(try await captureFile(at: source, kind: .image))
        try Data("{\"version\":".utf8).write(to: workspace.stateURL, options: [.atomic])

        let recovered = try TransferQueue(
            stateURL: workspace.stateURL,
            outboxURL: workspace.outboxURL,
            runner: RecordingCommandRunner()
        )
        let snapshot = await recovered.snapshot()
        XCTAssertEqual(snapshot.queueDepth, 1)
    }

    @Test
    func testMissingLedgerEntryIsReconstructedForPendingTransfer() async throws {
        let workspace = try TestWorkspace()
        let source = try workspace.write("missing-ledger.png")
        let first = try TransferQueue(
            stateURL: workspace.stateURL,
            outboxURL: workspace.outboxURL,
            runner: RecordingCommandRunner()
        )
        let capture = try await captureFile(at: source, kind: .image)
        try await first.enqueue(capture)
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: workspace.stateURL)) as? [String: Any])
        object["ledger"] = [String: Any]()
        try JSONSerialization.data(withJSONObject: object).write(to: workspace.stateURL, options: [.atomic])

        let recovered = try TransferQueue(
            stateURL: workspace.stateURL,
            outboxURL: workspace.outboxURL,
            runner: RecordingCommandRunner()
        )
        let disposition = await recovered.disposition(for: capture.identity)
        XCTAssertEqual(disposition, .pending)
    }

    @Test
    func testOrphanOutboxDirectoryIsQuarantinedOnLaunch() async throws {
        let workspace = try TestWorkspace()
        let orphan = workspace.outboxURL.appendingPathComponent("orphan", isDirectory: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data("unknown".utf8).write(to: orphan.appendingPathComponent("file.png"))

        _ = try TransferQueue(
            stateURL: workspace.stateURL,
            outboxURL: workspace.outboxURL,
            runner: RecordingCommandRunner()
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        let quarantine = workspace.outboxURL.deletingLastPathComponent().appendingPathComponent("Outbox Quarantine")
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantine.path))
    }

    @Test
    func testForceRetriesItemBeforeBackoffIsDue() async throws {
        let workspace = try TestWorkspace()
        let source = try workspace.write("force.mov")
        let runner = RecordingCommandRunner(results: [.success(.failure()), .success(.success)])
        let queue = try TransferQueue(
            stateURL: workspace.stateURL,
            outboxURL: workspace.outboxURL,
            runner: runner
        )
        try await queue.enqueue(try await captureFile(at: source, kind: .video))
        _ = await queue.process(configuration: configuration(captureDirectory: workspace.captureDirectory))

        let forced = await queue.process(
            configuration: configuration(captureDirectory: workspace.captureDirectory),
            force: true
        )

        XCTAssertEqual(forced.delivered, 1)
        XCTAssertEqual(runner.commands.count, 2)
    }

    @Test
    func testChangedSourceIsNeverUploadedUnderOldIdentity() async throws {
        let workspace = try TestWorkspace()
        let source = try workspace.write("changed.png")
        let runner = RecordingCommandRunner()
        let queue = try TransferQueue(
            stateURL: workspace.stateURL,
            outboxURL: workspace.outboxURL,
            runner: runner
        )
        try await queue.enqueue(try await captureFile(at: source, kind: .image))
        try Data("different bytes and size".utf8).write(to: source)

        let result = await queue.process(configuration: configuration(captureDirectory: workspace.captureDirectory))
        let snapshot = await queue.snapshot()

        XCTAssertEqual(result.failed, 1)
        XCTAssertTrue(runner.commands.isEmpty)
        XCTAssertTrue(snapshot.lastError?.contains("source changed") == true)
    }

    @Test
    func testInvalidConfigurationBlocksQueueProcessing() async throws {
        let workspace = try TestWorkspace()
        let source = try workspace.write("blocked.png")
        let runner = RecordingCommandRunner()
        let queue = try TransferQueue(
            stateURL: workspace.stateURL,
            outboxURL: workspace.outboxURL,
            runner: runner
        )
        try await queue.enqueue(try await captureFile(at: source, kind: .image))
        var invalid = configuration(captureDirectory: workspace.captureDirectory)
        invalid.sshDestination = "bad destination"

        let result = await queue.process(configuration: invalid)

        XCTAssertNotNil(result.blockedReason)
        XCTAssertTrue(runner.commands.isEmpty)
    }
}
