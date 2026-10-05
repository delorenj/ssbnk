import Foundation
import Testing
@testable import SSBNKClient

@Suite(.serialized)
struct TransferQueueTests {
    private func queue(_ workspace: TestWorkspace, uploader: CaptureUploading = ReadyUploadStub(), budget: UInt64 = 4 << 30) throws -> TransferQueue {
        try TransferQueue(stateURL: workspace.stateURL, outboxURL: workspace.outboxURL, runner: RecordingCommandRunner(), uploader: uploader, credentials: TestCredentialProvider(), stageBudget: budget, freeFloor: 0)
    }
    @Test
    func stagedBytesSurviveOriginalDeletionAndReadyPersistsBeforeCleanup() async throws {
        let workspace = try TestWorkspace()
        let source = try workspace.write("capture.png")
        let capture = try await captureFile(at: source, kind: .image)
        let first = try queue(workspace)
        try await first.enqueue(capture)
        let stagedSnapshot = await first.snapshot()
        let staged = try XCTUnwrap(stagedSnapshot.pending.first)
        try FileManager.default.removeItem(at: source)
        let resumed = try queue(workspace)
        let run = await resumed.process(configuration: configuration(captureDirectory: workspace.captureDirectory))
        XCTAssertEqual(run.delivered, 1)
        let history = await resumed.snapshot().history
        XCTAssertEqual(history.first?.phase, "ready")
        XCTAssertNotNil(history.first?.receipt?.result?.url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.stagedPath))
        let restarted = try queue(workspace)
        let disposition = await restarted.disposition(for: capture.identity)
        XCTAssertEqual(disposition, .delivered)
    }
    @Test
    func acceptanceIsNotOKAndPollingDoesNotDropStage() async throws {
        let workspace = try TestWorkspace()
        let uploader = ReadyUploadStub(state: "verifying")
        let queue = try queue(workspace, uploader: uploader)
        try await queue.enqueue(try await captureFile(at: workspace.write("video.mov"), kind: .video))
        let run = await queue.process(configuration: configuration(captureDirectory: workspace.captureDirectory))
        XCTAssertEqual(run.delivered, 0)
        let pendingSnapshot = await queue.snapshot()
        let pending = try XCTUnwrap(pendingSnapshot.pending.first)
        XCTAssertEqual(pending.phase, "verifying")
        XCTAssertNil(pending.receipt?.result)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.stagedPath))
    }
    @Test
    func corruptAndFutureLedgerFailClosedWithoutReset() throws {
        for data in [Data("{".utf8), Data("{\"version\":999}".utf8)] {
            let workspace = try TestWorkspace()
            try FileManager.default.createDirectory(at: workspace.stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: workspace.stateURL)
            do { _ = try queue(workspace); XCTFail("Corrupt/future ledger accepted") } catch {}
            XCTAssertEqual(try Data(contentsOf: workspace.stateURL), data)
        }
    }
    @Test
    func deferredCapacitySurvivesRestartAndRecovers() async throws {
        let workspace = try TestWorkspace()
        let source = try workspace.write("capacity.png")
        let limited = try queue(workspace, budget: 1)
        try await limited.enqueue(try await captureFile(at: source, kind: .image))
        let beforeSnapshot = await limited.snapshot()
        let before = try XCTUnwrap(beforeSnapshot.pending.first)
        XCTAssertEqual(before.phase, "deferred")
        XCTAssertFalse(FileManager.default.fileExists(atPath: before.stagedPath))
        let recovered = try queue(workspace)
        try await recovered.reconcileDeferred()
        let recoveredSnapshot = await recovered.snapshot()
        XCTAssertEqual(recoveredSnapshot.pending.first?.id, before.id)
        XCTAssertEqual(recoveredSnapshot.pending.first?.phase, "queued")
    }
    @Test
    func missingStageOnlyRebuildsFromMatchingOriginal() async throws {
        let workspace = try TestWorkspace()
        let source = try workspace.write("rebuild.png")
        let queue = try queue(workspace)
        try await queue.enqueue(try await captureFile(at: source, kind: .image))
        let transferSnapshot = await queue.snapshot()
        let transfer = try XCTUnwrap(transferSnapshot.pending.first)
        try FileManager.default.removeItem(atPath: transfer.stagedPath)
        try Data("different capture".utf8).write(to: source)
        let run = await queue.process(configuration: configuration(captureDirectory: workspace.captureDirectory))
        XCTAssertEqual(run.failed, 1)
        let failedSnapshot = await queue.snapshot()
        XCTAssertEqual(failedSnapshot.pending.first?.phase, "error")
    }
    @Test
    func clipboardClaimsAreConsumedBeforeWriteAndManualCopyFencesOlderCapture() async throws {
        let workspace = try TestWorkspace()
        let queue = try queue(workspace)
        let video = try await captureFile(at: workspace.write("older.mov"), kind: .video)
        let image = try await captureFile(at: workspace.write("newer.png"), kind: .image)
        try await queue.enqueue(video)
        try await queue.enqueue(image)
        _ = await queue.process(configuration: configuration(captureDirectory: workspace.captureDirectory))
        let rows = await queue.snapshot().history
        let older = try XCTUnwrap(rows.first { $0.kind == .video })
        let newer = try XCTUnwrap(rows.first { $0.kind == .image })
        let stale = try await queue.claimCopy(id: older.id)
        let eligible = try await queue.claimCopy(id: newer.id)
        let replay = try await queue.claimCopy(id: newer.id)
        let manual = try await queue.claimCopy(id: older.id, manual: true)
        XCTAssertNil(stale)
        XCTAssertNotNil(eligible)
        XCTAssertNil(replay)
        XCTAssertNotNil(manual)
        try await queue.finishCopy(id: older.id, warning: "copy failed")
        let afterCopy = await queue.snapshot()
        XCTAssertEqual(afterCopy.history.first { $0.id == older.id }?.phase, "ready")
    }
    @Test
    func singletonRejectsSecondOwner() throws {
        let workspace = try TestWorkspace()
        let first = try ClientSingleton(directory: workspace.root)
        do { _ = try ClientSingleton(directory: workspace.root); XCTFail("Second queue owner accepted") } catch {}
        withExtendedLifetime(first) {}
    }
    @Test
    func backoffIsBoundedAtThirtySeconds() {
        XCTAssertEqual(TransferQueue.retryDelay(afterAttempt: 1), 2)
        XCTAssertEqual(TransferQueue.retryDelay(afterAttempt: 100), 30)
    }
}
