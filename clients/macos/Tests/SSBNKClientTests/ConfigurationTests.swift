import Foundation
import Testing
@testable import SSBNKClient

@Suite(.serialized)
struct ConfigurationTests {
    @Test
    func legacyConfigurationMigratesSharedFolderAndHealthOrigin() throws {
        let workspace = try TestWorkspace()
        let file = workspace.root.appendingPathComponent("configuration.json")
        var legacy = ClientConfiguration.defaults(homeDirectory: workspace.root)
        legacy.version = nil; legacy.screenshotDirectory = nil; legacy.recordingDirectory = nil; legacy.apiOrigin = nil
        try JSONEncoder().encode(legacy).write(to: file)
        let migrated = try XCTUnwrap(ConfigurationStore(fileURL: file).load())
        XCTAssertEqual(migrated.screenshotDirectory, legacy.captureDirectory)
        XCTAssertEqual(migrated.recordingDirectory, legacy.captureDirectory)
        XCTAssertEqual(migrated.apiOrigin, "https://ss.delo.sh")
        XCTAssertEqual(migrated.version, 2)
        XCTAssertTrue(migrated.validationIssues().contains(.invalidVaultReference))
    }
    @Test
    func onlyHTTPSOrExplicitLoopbackOriginIsAllowed() {
        for value in ["http://ss.delo.sh", "https://user:pass@host", "https://host/api/uploads", "https://host?key=secret"] { XCTAssertFalse(ClientConfiguration.isSafeAPIOrigin(value)) }
        for value in ["https://ss.delo.sh", "http://127.0.0.1:13143", "http://localhost:13143"] { XCTAssertTrue(ClientConfiguration.isSafeAPIOrigin(value)) }
    }
    @Test
    func storesVaultReferenceNeverRawCredential() throws {
        let workspace = try TestWorkspace()
        let file = workspace.root.appendingPathComponent("settings/configuration.json")
        var value = configuration(captureDirectory: workspace.captureDirectory)
        value.version = 2; value.apiOrigin = value.resolvedOrigin
        value.screenshotDirectory = value.captureDirectory; value.recordingDirectory = value.captureDirectory
        let store = ConfigurationStore(fileURL: file)
        try store.save(value)
        XCTAssertEqual(try store.load(), value)
        let encoded = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(encoded.contains("DeLoSecrets"))
        XCTAssertFalse(encoded.contains("test-credential"))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}
