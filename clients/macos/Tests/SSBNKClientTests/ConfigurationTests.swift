import Foundation
import Testing
@testable import SSBNKClient

@Suite(.serialized)
struct ConfigurationTests {
    @Test
    func testDefaultsDescribeCurrentMacAndBothServerRoutes() {
        let home = URL(fileURLWithPath: "/Users/delorenj", isDirectory: true)
        let configuration = ClientConfiguration.defaults(homeDirectory: home)

        XCTAssertEqual(configuration.captureDirectory, "/Users/delorenj/Pictures/Screenshots")
        XCTAssertEqual(configuration.sshDestination, "delorenj@big-chungus.burro-salmon.ts.net")
        XCTAssertEqual(configuration.publicHealthURL, "https://ss.delo.sh/health")
        XCTAssertEqual(configuration.imageRemoteDirectory, "/home/delorenj/Pictures/Screenshots")
        XCTAssertEqual(configuration.videoRemoteDirectory, "/home/delorenj/Videos/Screencasts")
        XCTAssertEqual(configuration.mappings.map(\.sourceDirectory), [
            "/Users/delorenj/Pictures/Screenshots",
            "/Users/delorenj/Pictures/Screenshots",
        ])
        XCTAssertTrue(configuration.validationIssues().isEmpty)
    }

    @Test
    func testValidationRejectsCommandLikeDestinationsAndNonHTTPSHealth() {
        var configuration = ClientConfiguration.defaults()
        configuration.sshDestination = "host; touch /tmp/bad"
        configuration.publicHealthURL = "http://ss.delo.sh/health"
        configuration.videoRemoteDirectory = "/tmp/screen casts"

        XCTAssertEqual(configuration.validationIssues(), [
            .invalidSSHDestination,
            .invalidPublicHealthURL,
            .invalidRemoteDirectory(.video),
        ])
    }

    @Test
    func testConfigurationRoundTripsWithoutCredentialField() throws {
        let workspace = try TestWorkspace()
        let fileURL = workspace.root.appendingPathComponent("settings/configuration.json")
        let store = ConfigurationStore(fileURL: fileURL)
        let expected = ClientConfiguration.defaults(homeDirectory: URL(fileURLWithPath: "/Users/delorenj"))

        try store.save(expected)

        XCTAssertEqual(try store.load(), expected)
        let encoded = try String(contentsOf: fileURL, encoding: .utf8).lowercased()
        XCTAssertFalse(encoded.contains("upload_key"))
        XCTAssertFalse(encoded.contains("credential"))
        XCTAssertFalse(encoded.contains("password"))
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}
