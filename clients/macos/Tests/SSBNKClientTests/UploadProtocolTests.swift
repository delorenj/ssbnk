import Foundation
import Testing
@testable import SSBNKClient

@Suite(.serialized)
struct UploadProtocolTests {
    @Test
    func sharedReceiptFixturesParseWithoutInventingReady() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("protocol/fixtures/receipts.json"))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let receipts = try XCTUnwrap(object["receipts"] as? [[String: Any]])
        for object in receipts {
            let receipt = try JSONDecoder().decode(UploadReceipt.self, from: JSONSerialization.data(withJSONObject: object))
            let transfer = QueuedTransfer(id: UUID(uuidString: receipt.uuid)!, identity: CaptureIdentity(path: "/capture", size: UInt64(receipt.size), modificationNanoseconds: 0), kind: receipt.kind, sourcePath: "/capture", stagedPath: "/stage", createdAt: Date(), attempts: 0, nextAttemptAt: Date(), stagedSHA256: receipt.sha256, pinnedOrigin: "https://ss.delo.sh", pinnedProfile: receipt.profile)
            _ = try receipt.parsed(for: transfer)
            XCTAssertEqual(receipt.result != nil, receipt.state == "ready")
        }
    }
    @Test
    func invalidVaultReferenceFailsWithoutLaunchingOp() async throws {
        do { _ = try await UploadCredentialProvider().resolve(reference: "raw-secret"); XCTFail("Raw credential reference accepted") }
        catch let error as UploadFailure {
            XCTAssertFalse(error.message.contains("raw-secret"))
            XCTAssertEqual(error.code, "CREDENTIAL")
        }
    }
}
