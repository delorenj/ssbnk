import Foundation
#if os(macOS)
import Darwin
#else
import Glibc
#endif

protocol UploadCredentialProviding {
    func resolve(reference: String) async throws -> String
}

struct UploadCredentialProvider: UploadCredentialProviding {
    func resolve(reference: String) async throws -> String {
        try await Task.detached(priority: .utility) {
            guard reference.hasPrefix("op://DeLoSecrets/"), !reference.contains("\n"), !reference.contains("\0") else {
                throw UploadFailure(code: "CREDENTIAL", message: "Choose a DeLoSecrets op:// reference.", retryable: false)
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["op", "read", reference]
            let output = Pipe(), errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            process.standardInput = FileHandle.nullDevice
            try process.run()
            let stdout = output.fileHandleForReading.fileDescriptor
            let stderr = errors.fileHandleForReading.fileDescriptor
            _ = fcntl(stdout, F_SETFL, O_NONBLOCK)
            _ = fcntl(stderr, F_SETFL, O_NONBLOCK)
            var bytes = Data()
            var errorCount = 0
            var openDescriptors = Set([stdout, stderr])
            let deadline = Date().addingTimeInterval(15)
            defer {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                try? output.fileHandleForReading.close()
                try? errors.fileHandleForReading.close()
                bytes.resetBytes(in: 0..<bytes.count)
            }
            while !openDescriptors.isEmpty || process.isRunning {
                guard Date() < deadline, !Task.isCancelled else {
                    throw UploadFailure(code: "CREDENTIAL", message: "Vault resolution timed out; authorize 1Password CLI.", retryable: false)
                }
                for descriptor in Array(openDescriptors) {
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    let count = read(descriptor, &buffer, buffer.count)
                    if count == 0 { openDescriptors.remove(descriptor); continue }
                    if count < 0 {
                        if errno == EAGAIN || errno == EWOULDBLOCK { continue }
                        throw UploadFailure(code: "CREDENTIAL", message: "Credential pipe failed.", retryable: false)
                    }
                    if descriptor == stdout { bytes.append(contentsOf: buffer.prefix(count)) }
                    else { errorCount += count }
                    guard bytes.count <= 8192, errorCount <= 8192 else {
                        throw UploadFailure(code: "CREDENTIAL", message: "Vault response exceeded memory bound.", retryable: false)
                    }
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            guard process.terminationStatus == 0, let value = String(data: bytes, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty, !value.contains("\n"), !value.contains("\r"), !value.contains("\0") else {
                throw UploadFailure(code: "CREDENTIAL", message: "Vault access denied or malformed; unlock and authorize 1Password CLI.", retryable: false)
            }
            return value
        }.value
    }
}
