import Foundation
import Testing
@testable import SSBNKClient

@Suite(.serialized)
struct HealthMonitorTests {
    @Test
    func authenticatedCapabilitiesReplaceSSHProbes() async throws {
        let workspace = try TestWorkspace()
        try FileManager.default.createDirectory(at: workspace.outboxURL, withIntermediateDirectories: true)
        let runner = RecordingCommandRunner()
        let uploader = ReadyUploadStub()
        let monitor = HealthMonitor(runner: runner, outboxURL: workspace.outboxURL, uploader: uploader, credentials: TestCredentialProvider())
        let report = await monitor.check(configuration: configuration(captureDirectory: workspace.captureDirectory), queue: TransferQueueSnapshot(queueDepth: 0, lastSuccessAt: nil, lastError: nil, isProcessing: false, pending: []))
        XCTAssertEqual(report.state, .healthy)
        XCTAssertTrue(runner.commands.isEmpty)
    }
    @Test
    func unavailableRootReportsIndependentRemedy() async throws {
        let workspace = try TestWorkspace()
        try FileManager.default.createDirectory(at: workspace.outboxURL, withIntermediateDirectories: true)
        var value = configuration(captureDirectory: workspace.captureDirectory)
        value.recordingDirectory = workspace.root.appendingPathComponent("missing").path
        let monitor = HealthMonitor(runner: RecordingCommandRunner(), outboxURL: workspace.outboxURL, uploader: ReadyUploadStub(), credentials: TestCredentialProvider())
        let report = await monitor.check(configuration: value, queue: TransferQueueSnapshot(queueDepth: 0, lastSuccessAt: nil, lastError: nil, isProcessing: false, pending: []))
        XCTAssertEqual(report.state, .needsAttention)
        XCTAssertTrue(report.remedy?.contains("screenshots and staged transfers continue") == true)
    }
}
