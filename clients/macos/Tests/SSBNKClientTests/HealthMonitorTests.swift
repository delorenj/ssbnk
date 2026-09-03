import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import SSBNKClient

@Suite(.serialized)
struct HealthMonitorTests {
    @Test
    func testHealthyRequiresLocalPublicSSHAndBothWriteChecks() async throws {
        let workspace = try TestWorkspace()
        try FileManager.default.createDirectory(at: workspace.outboxURL, withIntermediateDirectories: true)
        let runner = RecordingCommandRunner(results: [
            .success(.success),
            .success(.success),
            .success(.success),
        ])
        let monitor = HealthMonitor(
            runner: runner,
            publicHealthChecker: StubPublicHealthChecker(PublicHealthResult(reachable: true, detail: nil)),
            outboxURL: workspace.outboxURL
        )
        let queue = TransferQueueSnapshot(
            queueDepth: 0,
            lastSuccessAt: nil,
            lastError: nil,
            isProcessing: false,
            pending: []
        )

        let report = await monitor.check(
            configuration: configuration(captureDirectory: workspace.captureDirectory),
            queue: queue
        )

        XCTAssertEqual(report.state, .healthy)
        XCTAssertNil(report.remedy)
        XCTAssertEqual(runner.commands.count, 3)
        XCTAssertEqual(
            runner.commands[0],
            SSBNKCommands.sshProbe(destination: "delorenj@big-chungus.burro-salmon.ts.net")
        )
        XCTAssertEqual(runner.commands[1].arguments.suffix(3), [
            "/usr/bin/test", "-w", "/home/delorenj/Pictures/Screenshots",
        ])
        XCTAssertEqual(runner.commands[2].arguments.suffix(3), [
            "/usr/bin/test", "-w", "/home/delorenj/Videos/Screencasts",
        ])
    }

    @Test
    func testMissingCaptureFolderGivesSpecificNeedsAttentionRemedy() async throws {
        let workspace = try TestWorkspace()
        try FileManager.default.createDirectory(at: workspace.outboxURL, withIntermediateDirectories: true)
        let missing = workspace.root.appendingPathComponent("missing", isDirectory: true)
        let runner = RecordingCommandRunner(results: [
            .success(.success), .success(.success), .success(.success),
        ])
        let monitor = HealthMonitor(
            runner: runner,
            publicHealthChecker: StubPublicHealthChecker(PublicHealthResult(reachable: true, detail: nil)),
            outboxURL: workspace.outboxURL
        )

        let report = await monitor.check(
            configuration: configuration(captureDirectory: missing),
            queue: TransferQueueSnapshot(
                queueDepth: 0,
                lastSuccessAt: nil,
                lastError: nil,
                isProcessing: false,
                pending: []
            )
        )

        XCTAssertEqual(report.state, .needsAttention)
        XCTAssertEqual(report.remedy, "Choose an existing, readable capture folder in Settings.")
    }

    @Test
    func testHealthReductionDistinguishesSyncingAndFailedOfflineQueue() {
        var inputs = allHealthyInputs
        inputs.queueDepth = 2
        XCTAssertEqual(HealthMonitor.reduce(inputs), .syncing)

        inputs.lastSyncError = "network unavailable"
        inputs.batchSSHAvailable = false
        XCTAssertEqual(HealthMonitor.reduce(inputs), .needsAttention)

        inputs.queueDepth = 0
        inputs.lastSyncError = nil
        inputs.batchSSHAvailable = true
        XCTAssertEqual(HealthMonitor.reduce(inputs), .healthy)
    }

    @Test
    func testEveryHealthyPrerequisiteIndependentlyReducesToNeedsAttention() {
        let prerequisites: [WritableKeyPath<HealthInputs, Bool>] = [
            \HealthInputs.configurationValid,
            \HealthInputs.captureDirectoryAvailable,
            \HealthInputs.outboxAvailable,
            \HealthInputs.publicHealthReachable,
            \HealthInputs.batchSSHAvailable,
            \HealthInputs.imageDirectoryWritable,
            \HealthInputs.videoDirectoryWritable,
        ]

        for prerequisite in prerequisites {
            var inputs = allHealthyInputs
            inputs[keyPath: prerequisite] = false
            XCTAssertEqual(HealthMonitor.reduce(inputs), .needsAttention)
        }

        var syncError = allHealthyInputs
        syncError.lastSyncError = "failed"
        XCTAssertEqual(HealthMonitor.reduce(syncError), .needsAttention)

        var active = allHealthyInputs
        active.isSyncing = true
        XCTAssertEqual(HealthMonitor.reduce(active), .syncing)
    }

    @Test
    func testPublicHealthRequiresOKJSONStatus() async throws {
        let url = try XCTUnwrap(URL(string: "https://ss.delo.sh/health"))
        let ok = URLSessionPublicHealthChecker(loader: StubHTTPDataLoader(response: .success((
            Data("{\"status\":\"ok\"}".utf8),
            response(url: url, status: 200)
        ))))
        let warning = URLSessionPublicHealthChecker(loader: StubHTTPDataLoader(response: .success((
            Data("{\"status\":\"warning\",\"consistency_issues\":[\"missing metadata\"]}".utf8),
            response(url: url, status: 200)
        ))))
        let wrongCase = URLSessionPublicHealthChecker(loader: StubHTTPDataLoader(response: .success((
            Data("{\"status\":\"OK\"}".utf8),
            response(url: url, status: 200)
        ))))

        let okResult = await ok.check(url)
        XCTAssertEqual(okResult, PublicHealthResult(reachable: true, detail: nil))
        let warningResult = await warning.check(url)
        XCTAssertFalse(warningResult.reachable)
        XCTAssertTrue(warningResult.detail?.contains("warning: missing metadata") == true)
        let wrongCaseResult = await wrongCase.check(url)
        XCTAssertFalse(wrongCaseResult.reachable)
        XCTAssertTrue(wrongCaseResult.detail?.contains("reported OK") == true)
    }

    @Test
    func testPublicHealthRejectsNon2xxInvalidJSONAndTransportFailure() async throws {
        let url = try XCTUnwrap(URL(string: "https://ss.delo.sh/health"))
        let non2xx = URLSessionPublicHealthChecker(loader: StubHTTPDataLoader(response: .success((
            Data("{\"status\":\"ok\"}".utf8),
            response(url: url, status: 503)
        ))))
        let invalid = URLSessionPublicHealthChecker(loader: StubHTTPDataLoader(response: .success((
            Data("not-json".utf8),
            response(url: url, status: 200)
        ))))
        let transport = URLSessionPublicHealthChecker(loader: StubHTTPDataLoader(
            response: .failure(URLError(.notConnectedToInternet))
        ))

        let non2xxResult = await non2xx.check(url)
        let invalidResult = await invalid.check(url)
        let transportResult = await transport.check(url)
        XCTAssertTrue(non2xxResult.detail?.contains("HTTP 503") == true)
        XCTAssertTrue(invalidResult.detail?.contains("invalid JSON") == true)
        XCTAssertFalse(transportResult.reachable)
        XCTAssertNotNil(transportResult.detail)
    }

    private var allHealthyInputs: HealthInputs {
        HealthInputs(
            configurationValid: true,
            captureDirectoryAvailable: true,
            outboxAvailable: true,
            publicHealthReachable: true,
            batchSSHAvailable: true,
            imageDirectoryWritable: true,
            videoDirectoryWritable: true,
            queueDepth: 0,
            isSyncing: false,
            lastSyncError: nil
        )
    }

    private func response(url: URL, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }
}
