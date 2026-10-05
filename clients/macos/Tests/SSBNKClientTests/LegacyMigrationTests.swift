import Foundation
import Testing
@testable import SSBNKClient

@Suite(.serialized)
struct LegacyMigrationTests {
    @Test
    func incompleteHandoverPreservesLegacyAndPlaintextConfiguration() async throws {
        let workspace = try TestWorkspace()
        let credential = workspace.root.appendingPathComponent(".config/ssbnk/remote.env")
        try FileManager.default.createDirectory(at: credential.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("nonsecret legacy placeholder".utf8).write(to: credential)
        let runner = RecordingCommandRunner()
        let migration = LegacyMigration(homeDirectory: workspace.root, runner: runner)
        do { try await migration.retire(replacementHealth: .healthy, confirmed: true); XCTFail("Unqualified handover accepted") }
        catch let error as UploadFailure { XCTAssertEqual(error.code, "HANDOVER_REQUIRED") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: credential.path))
        XCTAssertTrue(runner.commands.isEmpty)
    }
    @Test
    func failedCutoverReenablesLegacyAndPreservesFiles() async throws {
        let workspace = try TestWorkspace()
        let runner = RecordingCommandRunner(results: [.success(.success), .success(.failure("bootout denied")), .success(.success), .success(.success)])
        let migration = LegacyMigration(homeDirectory: workspace.root, runner: runner, uid: 501)
        var boundary = false
        do {
            try await migration.cutover(configuration: configuration(captureDirectory: workspace.captureDirectory), controlledReady: {}, persistBoundary: { boundary = true }, commitHandover: { XCTFail("Failed cutover committed") }, confirmed: true, credentials: TestCredentialProvider())
            XCTFail("Failed bootout accepted")
        } catch {}
        XCTAssertTrue(boundary)
        XCTAssertTrue(runner.commands.contains { $0.arguments.first == "enable" })
        XCTAssertTrue(runner.commands.contains { $0.arguments.first == "bootstrap" })
    }

    @Test
    func loadedLegacyJobIsDetectedWithoutPlist() async throws {
        let workspace = try TestWorkspace()
        let runner = RecordingCommandRunner()
        let present = await LegacyMigration(homeDirectory: workspace.root, runner: runner).detectPresence()
        XCTAssertTrue(present)
    }
}
