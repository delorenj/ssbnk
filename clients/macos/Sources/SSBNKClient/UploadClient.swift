import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

struct UploadFailure: Codable, Equatable, Error, LocalizedError {
    let code: String
    let message: String
    let retryable: Bool
    var errorDescription: String? { message }
}

struct UploadResult: Codable, Equatable {
    let url: String
    let filename: String
    let metadataID: String
    let mediaType: String
    let size: Int64
    let sha256: String
    let availability: String
    enum CodingKeys: String, CodingKey {
        case url, filename, size, sha256, availability
        case metadataID = "metadata_id", mediaType = "media_type"
    }
}

struct UploadReceipt: Codable, Equatable {
    let version: Int
    let uuid: String
    let kind: MediaKind
    let profile: String
    let size: Int64
    let sha256: String
    let offset: Int64
    let state: String
    let attempt: Int
    let acceptedAt: String?
    let error: UploadFailure?
    let result: UploadResult?
    enum CodingKeys: String, CodingKey {
        case version, uuid, kind, profile, size, sha256, offset, state, attempt, error, result
        case acceptedAt = "accepted_at"
    }

    func parsed(for transfer: QueuedTransfer) throws -> UploadReceipt {
        guard version == 2, uuid == transfer.id.uuidString.lowercased(), kind == transfer.kind,
              profile == transfer.uploadProfile, size == Int64(transfer.identity.size),
              sha256 == transfer.stagedSHA256, offset >= 0, offset <= size,
              (1...3).contains(attempt),
              ["receiving", "verifying", "queued", "processing", "ready", "failed", "expired"].contains(state)
        else { throw UploadFailure(code: "PROTOCOL", message: "Receipt differs from this capture's immutable identity.", retryable: false) }
        if transfer.receipt?.acceptedAt != nil && state == "receiving" {
            throw UploadFailure(code: "STATE_CONFLICT", message: "Accepted UUID regressed to receiving; repair server storage.", retryable: false)
        }
        if ["verifying", "queued", "processing", "ready"].contains(state) {
            guard offset == size, acceptedAt != nil else {
                throw UploadFailure(code: "PROTOCOL", message: "Accepted receipt is incomplete.", retryable: false)
            }
        }
        guard (state == "ready") == (result != nil) else {
            throw UploadFailure(code: "PROTOCOL", message: "Only ready receipts may contain hosted results.", retryable: false)
        }
        if let result {
            guard result.metadataID == uuid, result.filename.hasPrefix(uuid + "."),
                  !result.filename.contains("/"), !result.filename.contains("\\"),
                  result.url == (transfer.pinnedOrigin ?? "") + "/" + result.filename,
                  ["available", "expired"].contains(result.availability), result.size > 0,
                  result.sha256.count == 64,
                  kind != .video || result.mediaType == "image/gif"
            else { throw UploadFailure(code: "PROTOCOL", message: "Ready output does not match the committed UUID.", retryable: false) }
        }
        return self
    }
}

struct UploadCapabilities: Decodable {
    let version: Int
    let processingReady: Bool
    let limits: Limits
    struct Limits: Decodable {
        let defaultChunkBytes: Int
        enum CodingKeys: String, CodingKey { case defaultChunkBytes = "default_chunk_bytes" }
    }
    enum CodingKeys: String, CodingKey {
        case version, limits
        case processingReady = "processing_ready"
    }
}

protocol CaptureUploading {
    func advance(_ transfer: QueuedTransfer, credential: String) async throws -> UploadReceipt
    func capabilities(origin: String, credential: String) async throws -> UploadCapabilities
    func retry(_ transfer: QueuedTransfer, credential: String) async throws -> UploadReceipt
}

final class RefuseUploadRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

final class UploadClient: CaptureUploading {
    private let session: URLSession
    private let redirectDelegate = RefuseUploadRedirects()

    init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 60
        self.session = session ?? URLSession(configuration: configuration, delegate: redirectDelegate, delegateQueue: nil)
    }

    func capabilities(origin: String, credential: String) async throws -> UploadCapabilities {
        let (_, data) = try await request(origin: origin, path: "/capabilities", method: "GET", credential: credential)
        guard let capabilities = try? JSONDecoder().decode(UploadCapabilities.self, from: data),
              capabilities.version == 2, (65_536...4_194_304).contains(capabilities.limits.defaultChunkBytes)
        else { throw UploadFailure(code: "UPGRADE_REQUIRED", message: "Server upgrade required; HTTP v2 is unavailable. No SSH fallback.", retryable: false) }
        return capabilities
    }

    func advance(_ transfer: QueuedTransfer, credential: String) async throws -> UploadReceipt {
        guard let origin = transfer.pinnedOrigin, transfer.stagedSHA256 != nil else {
            throw UploadFailure(code: "STATE", message: "Capture is not pinned and staged.", retryable: false)
        }
        let capabilities = try await capabilities(origin: origin, credential: credential)
        let path = "/" + transfer.id.uuidString.lowercased()
        let (status, statusData) = try await request(origin: origin, path: path, method: "GET", credential: credential)
        var receipt: UploadReceipt
        if status == 404 {
            guard transfer.receipt?.acceptedAt == nil, transfer.receipt?.offset != Int64(transfer.identity.size) else {
                throw UploadFailure(code: "UPLOAD_UNKNOWN", message: "Accepted UUID disappeared; repair server storage.", retryable: false)
            }
            let descriptor: [String: Any] = [
                "version": 2, "original_name": URL(fileURLWithPath: transfer.sourcePath).lastPathComponent,
                "kind": transfer.kind.rawValue, "size": transfer.identity.size,
                "sha256": transfer.stagedSHA256!, "profile": transfer.uploadProfile,
                "capture_time": ISO8601DateFormatter().string(from: transfer.createdAt),
            ]
            let body = try JSONSerialization.data(withJSONObject: descriptor)
            let (_, reserved) = try await request(origin: origin, path: path, method: "PUT", credential: credential, body: body)
            receipt = try decode(reserved, transfer: transfer)
        } else {
            receipt = try decode(statusData, transfer: transfer)
        }
        guard receipt.state == "receiving" else { return receipt }
        if receipt.offset == receipt.size {
            let (_, completed) = try await request(origin: origin, path: path + "/complete", method: "POST", credential: credential)
            return try decode(completed, transfer: transfer)
        }
        let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: transfer.stagedPath))
        defer { try? file.close() }
        try file.seek(toOffset: UInt64(receipt.offset))
        let data = try file.read(upToCount: min(capabilities.limits.defaultChunkBytes, Int(receipt.size - receipt.offset))) ?? Data()
        guard !data.isEmpty else { throw UploadFailure(code: "STAGE", message: "Staged input is shorter than expected.", retryable: false) }
        let (_, reply) = try await request(origin: origin, path: path + "/chunks", method: "PUT", credential: credential, body: data,
                                          headers: ["Upload-Offset": String(receipt.offset), "Upload-Chunk-SHA256": try CaptureHash.data(data)], timeout: 60)
        return try decode(reply, transfer: transfer)
    }

    func retry(_ transfer: QueuedTransfer, credential: String) async throws -> UploadReceipt {
        guard let origin = transfer.pinnedOrigin, let receipt = transfer.receipt else {
            throw UploadFailure(code: "STATE", message: "No server attempt is available to retry.", retryable: false)
        }
        let body = try JSONSerialization.data(withJSONObject: ["expectedAttempt": receipt.attempt])
        let (_, response) = try await request(origin: origin, path: "/" + transfer.id.uuidString.lowercased() + "/retry", method: "POST", credential: credential, body: body)
        return try decode(response, transfer: transfer)
    }

    private func decode(_ data: Data, transfer: QueuedTransfer) throws -> UploadReceipt {
        let receipt = try JSONDecoder().decode(UploadReceipt.self, from: data)
        return try receipt.parsed(for: transfer)
    }

    private func request(origin: String, path: String, method: String, credential: String,
                         body: Data? = nil, headers: [String: String] = [:], timeout: TimeInterval = 15) async throws -> (Int, Data) {
        guard ClientConfiguration.isSafeAPIOrigin(origin), let url = URL(string: origin + "/api/uploads" + path) else {
            throw UploadFailure(code: "ORIGIN", message: "Use HTTPS or an explicit loopback development origin.", retryable: false)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.httpBody = body
        request.setValue(credential, forHTTPHeaderField: "X-Upload-Key")
        request.setValue(String(body?.count ?? 0), forHTTPHeaderField: "Content-Length")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        do {
            #if os(macOS)
            let (stream, response) = try await session.bytes(for: request)
            var data = Data()
            for try await byte in stream {
                guard data.count < 65_536 else { throw UploadFailure(code: "PROTOCOL", message: "Control response exceeds memory bound.", retryable: false) }
                data.append(byte)
            }
            #else
            let (data, response) = try await session.data(for: request)
            #endif
            guard let response = response as? HTTPURLResponse, data.count <= 65_536 else {
                throw UploadFailure(code: "PROTOCOL", message: "Invalid or oversized control response.", retryable: false)
            }
            if (300...399).contains(response.statusCode) { throw UploadFailure(code: "REDIRECT", message: "Redirect refused; configure the final origin.", retryable: false) }
            if response.statusCode == 401 { throw UploadFailure(code: "UNAUTHORIZED", message: "Credential rejected; fix vault access.", retryable: false) }
            if response.statusCode == 410 { throw UploadFailure(code: "UPLOAD_EXPIRED", message: "UUID expired permanently; never recreate silently.", retryable: false) }
            if response.statusCode == 409 { throw UploadFailure(code: "CONFLICT", message: "Upload conflict; reconcile the same UUID.", retryable: true) }
            if response.statusCode >= 500 { throw UploadFailure(code: "SERVER", message: "Origin or proxy unavailable; reconcile before retry.", retryable: true) }
            guard response.statusCode < 400 || response.statusCode == 404 else {
                throw UploadFailure(code: "REJECTED", message: "Server rejected the upload.", retryable: false)
            }
            return (response.statusCode, data)
        } catch let error as UploadFailure { throw error }
        catch { throw UploadFailure(code: "NETWORK", message: "Network interrupted; reconcile this UUID before retry.", retryable: true) }
    }
}

enum CaptureHash {
    static func file(_ url: URL) throws -> String {
        #if canImport(CryptoKit)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
        #else
        return try linuxHash(file: url, bytes: nil)
        #endif
    }
    static func data(_ data: Data) throws -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        return try linuxHash(file: nil, bytes: data)
        #endif
    }
    #if !canImport(CryptoKit)
    private static func linuxHash(file: URL?, bytes: Data?) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sha256sum")
        process.arguments = file.map { ["--", $0.path] } ?? []
        let output = Pipe(), input = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = bytes == nil ? FileHandle.nullDevice : input
        try process.run()
        if let bytes { try input.fileHandleForWriting.write(contentsOf: bytes); try input.fileHandleForWriting.close() }
        let response = try output.fileHandleForReading.read(upToCount: 4096) ?? Data()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let text = String(data: response, encoding: .utf8), text.count >= 64 else {
            throw UploadFailure(code: "HASH", message: "Capture hashing failed.", retryable: false)
        }
        return String(text.prefix(64))
    }
    #endif
}
