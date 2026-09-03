import Foundation
import Testing
@testable import SSBNKClient

@Suite(.serialized)
struct LegacyMigrationTests {
    @Test
    func testMigrationRequiresConfirmationAndHealthyReplacementThenRemovesCredential() async throws {
        let workspace = try TestWorkspace()
        let home = workspace.root.appendingPathComponent("home", isDirectory: true)
        let plist = home.appendingPathComponent("Library/LaunchAgents/sh.delo.ss.remote-upload.plist")
        let credentials = home.appendingPathComponent(".config/ssbnk/remote.env")
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: credentials.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("plist".utf8).write(to: plist)
        try Data("legacy credential configuration".utf8).write(to: credentials)
        let runner = RecordingCommandRunner(results: [.success(.success)])
        let migration = LegacyMigration(homeDirectory: home, runner: runner, uid: 501)

        do {
            try await migration.retire(replacementHealth: .healthy, confirmed: false)
            XCTFail("migration should require confirmation")
        } catch {
            XCTAssertEqual(error as? LegacyMigrationError, .confirmationRequired)
        }
        do {
            try await migration.retire(replacementHealth: .syncing, confirmed: true)
            XCTFail("migration should require a healthy replacement")
        } catch {
            XCTAssertEqual(error as? LegacyMigrationError, .replacementNotHealthy)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: plist.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: credentials.path))

        try await migration.retire(replacementHealth: .healthy, confirmed: true)

        XCTAssertFalse(migration.isPresent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plist.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: credentials.path))
        XCTAssertEqual(runner.commands, [
            SSBNKCommands.legacyAgentStatus(uid: 501),
            SSBNKCommands.disableLegacyAgent(uid: 501),
        ])
    }

    @Test
    func testFailedLegacyBootoutPreservesPlistAndCredential() async throws {
        let workspace = try TestWorkspace()
        let home = workspace.root.appendingPathComponent("home", isDirectory: true)
        let plist = home.appendingPathComponent("Library/LaunchAgents/sh.delo.ss.remote-upload.plist")
        let credentials = home.appendingPathComponent(".config/ssbnk/remote.env")
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: credentials.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("plist".utf8).write(to: plist)
        try Data("credential config".utf8).write(to: credentials)
        let runner = RecordingCommandRunner(results: [
            .success(.success),
            .success(.failure("operation not permitted")),
        ])
        let migration = LegacyMigration(homeDirectory: home, runner: runner, uid: 501)

        do {
            try await migration.retire(replacementHealth: .healthy, confirmed: true)
            XCTFail("failed bootout must stop migration")
        } catch let error as LegacyMigrationError {
            XCTAssertTrue(error.localizedDescription.contains("operation not permitted"))
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: plist.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: credentials.path))
    }

    @Test
    func testLoadedLegacyJobIsDetectedWithoutPlist() async throws {
        let workspace = try TestWorkspace()
        let runner = RecordingCommandRunner(results: [.success(.success)])
        let migration = LegacyMigration(homeDirectory: workspace.root, runner: runner, uid: 501)

        let isPresent = await migration.detectPresence()
        XCTAssertTrue(isPresent)
        XCTAssertEqual(runner.commands, [SSBNKCommands.legacyAgentStatus(uid: 501)])
    }
}
