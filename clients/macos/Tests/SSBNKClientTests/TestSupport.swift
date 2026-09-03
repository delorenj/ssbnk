import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import SSBNKClient

final class TestWorkspace {
    let root: URL
    let captureDirectory: URL
    let stateURL: URL
    let outboxURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ssbnk-client-tests-\(UUID().uuidString)", isDirectory: true)
        captureDirectory = root.appendingPathComponent("Captures", isDirectory: true)
        stateURL = root.appendingPathComponent("State/sync-state.json")
        outboxURL = root.appendingPathComponent("State/Outbox", isDirectory: true)
        try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func write(_ name: String, contents: Data = Data("capture".utf8)) throws -> URL {
        let url = captureDirectory.appendingPathComponent(name)
        try contents.write(to: url)
        return url
    }
}

final class RecordingCommandRunner: CommandRunning {
    var commands: [Command] = []
    var results: [Result<CommandResult, Error>]

    init(results: [Result<CommandResult, Error>] = []) {
        self.results = results
    }

    func run(_ command: Command) async throws -> CommandResult {
        commands.append(command)
        if results.isEmpty {
            return .success
        }
        return try results.removeFirst().get()
    }
}

extension CommandResult {
    static let success = CommandResult(exitCode: 0, standardOutput: "", standardError: "")

    static func failure(_ message: String = "offline", exitCode: Int32 = 255) -> CommandResult {
        CommandResult(exitCode: exitCode, standardOutput: "", standardError: message)
    }
}

struct ImmediateStableChecker: FileStabilityChecking {
    func stableCapture(at url: URL, kind: MediaKind) async -> CaptureFile? {
        guard let identity = CaptureIdentity.current(at: url), identity.size > 0 else { return nil }
        return CaptureFile(
            url: url,
            identity: identity,
            kind: kind
        )
    }
}

final class StubPublicHealthChecker: PublicHealthChecking {
    var result: PublicHealthResult

    init(_ result: PublicHealthResult) {
        self.result = result
    }

    func check(_ url: URL) async -> PublicHealthResult { result }
}

struct StubHTTPDataLoader: HTTPDataLoading {
    let response: Result<(Data, HTTPURLResponse), Error>

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try response.get()
    }
}

enum TestFailure: Error, LocalizedError {
    case injected(String)

    var errorDescription: String? {
        switch self {
        case .injected(let message): return message
        }
    }
}

private func assertionComment(_ message: String, fallback: @autoclosure () -> String) -> Comment {
    Comment(rawValue: message.isEmpty ? fallback() : message)
}

func XCTFail(
    _ message: @autoclosure () -> String = "",
    sourceLocation: SourceLocation = #_sourceLocation
) {
    Issue.record(
        assertionComment(message(), fallback: "Explicit test failure"),
        sourceLocation: sourceLocation
    )
}

func XCTAssertTrue(
    _ expression: @autoclosure () throws -> Bool,
    _ message: @autoclosure () -> String = "",
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        guard try expression() else {
            Issue.record(
                assertionComment(message(), fallback: "Expected expression to be true"),
                sourceLocation: sourceLocation
            )
            return
        }
    } catch {
        Issue.record(error, sourceLocation: sourceLocation)
    }
}

func XCTAssertFalse(
    _ expression: @autoclosure () throws -> Bool,
    _ message: @autoclosure () -> String = "",
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        guard try !expression() else {
            Issue.record(
                assertionComment(message(), fallback: "Expected expression to be false"),
                sourceLocation: sourceLocation
            )
            return
        }
    } catch {
        Issue.record(error, sourceLocation: sourceLocation)
    }
}

func XCTAssertNil<T>(
    _ expression: @autoclosure () throws -> T?,
    _ message: @autoclosure () -> String = "",
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        guard try expression() == nil else {
            Issue.record(
                assertionComment(message(), fallback: "Expected value to be nil"),
                sourceLocation: sourceLocation
            )
            return
        }
    } catch {
        Issue.record(error, sourceLocation: sourceLocation)
    }
}

func XCTAssertNotNil<T>(
    _ expression: @autoclosure () throws -> T?,
    _ message: @autoclosure () -> String = "",
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        guard try expression() != nil else {
            Issue.record(
                assertionComment(message(), fallback: "Expected value not to be nil"),
                sourceLocation: sourceLocation
            )
            return
        }
    } catch {
        Issue.record(error, sourceLocation: sourceLocation)
    }
}

func XCTAssertEqual<T: Equatable>(
    _ expression1: @autoclosure () throws -> T,
    _ expression2: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        let actual = try expression1()
        let expected = try expression2()
        guard actual != expected else { return }
        Issue.record(
            assertionComment(
                message(),
                fallback: "Expected \(String(describing: actual)) to equal \(String(describing: expected))"
            ),
            sourceLocation: sourceLocation
        )
    } catch {
        Issue.record(error, sourceLocation: sourceLocation)
    }
}

func XCTAssertLessThan<T: Comparable>(
    _ expression1: @autoclosure () throws -> T,
    _ expression2: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        let actual = try expression1()
        let upperBound = try expression2()
        guard actual < upperBound else {
            Issue.record(
                assertionComment(
                    message(),
                    fallback: "Expected \(String(describing: actual)) to be less than \(String(describing: upperBound))"
                ),
                sourceLocation: sourceLocation
            )
            return
        }
    } catch {
        Issue.record(error, sourceLocation: sourceLocation)
    }
}

private struct TestUnwrapError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

func XCTUnwrap<T>(
    _ expression: @autoclosure () throws -> T?,
    _ message: @autoclosure () -> String = ""
) throws -> T {
    if let value = try expression() {
        return value
    }
    let detail = message()
    throw TestUnwrapError(message: detail.isEmpty ? "Expected optional value not to be nil" : detail)
}

final class ConditionalQueueStateStore: QueueStatePersisting {
    private let backing = AtomicQueueStateStore()
    var shouldFail: (Data) -> Bool

    init(shouldFail: @escaping (Data) -> Bool) {
        self.shouldFail = shouldFail
    }

    func load(from url: URL) throws -> Data? {
        try backing.load(from: url)
    }

    func save(_ data: Data, to url: URL) throws {
        if shouldFail(data) { throw TestFailure.injected("state disk unavailable") }
        try backing.save(data, to: url)
    }
}

final class TestClock {
    var date: Date

    init(_ date: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.date = date
    }

    func now() -> Date { date }
    func advance(_ seconds: TimeInterval) { date = date.addingTimeInterval(seconds) }
}

func configuration(captureDirectory: URL) -> ClientConfiguration {
    var configuration = ClientConfiguration.defaults(homeDirectory: captureDirectory.deletingLastPathComponent())
    configuration.captureDirectory = captureDirectory.path
    return configuration
}

func captureFile(at url: URL, kind: MediaKind) async throws -> CaptureFile {
    let capture = await ImmediateStableChecker().stableCapture(at: url, kind: kind)
    return try XCTUnwrap(capture)
}
