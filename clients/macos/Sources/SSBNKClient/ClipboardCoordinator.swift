import Foundation
#if os(macOS)
import AppKit
import Darwin
#else
import Glibc
#endif

func synchronizeDirectory(_ url: URL) throws {
    let descriptor = open(url.path, O_RDONLY)
    guard descriptor >= 0 else { throw UploadFailure(code: "STORAGE", message: "Private directory could not be opened for durable synchronization.", retryable: false) }
    defer { close(descriptor) }
    guard fsync(descriptor) == 0 else { throw UploadFailure(code: "STORAGE_UNCERTAIN", message: "Private directory durability could not be confirmed; stop and reconcile state.", retryable: false) }
}

final class ClientSingleton {
    private let descriptor: Int32
    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent("client.lock").path
        descriptor = open(path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if descriptor >= 0 { close(descriptor) }
            throw UploadFailure(code: "SINGLETON", message: "SSBNK Client is already running.", retryable: false)
        }
    }
    deinit { close(descriptor) }
}

#if os(macOS)
@MainActor
final class ClipboardCoordinator {
    private let queue: TransferQueue
    init(queue: TransferQueue) { self.queue = queue }
    func copy(id: UUID, manual: Bool = false) async {
        do {
            guard let transfer = try await queue.claimCopy(id: id, manual: manual), let url = transfer.receipt?.result?.url else { return }
            NSPasteboard.general.clearContents()
            let succeeded = NSPasteboard.general.setString(url, forType: .string)
            try await queue.finishCopy(id: id, warning: succeeded ? nil : "Clipboard write failed; Retry copy remains available.")
        } catch {
            try? await queue.finishCopy(id: id, warning: "Copy state could not be saved; use Retry copy.")
        }
    }
}
#endif
