import Foundation
import Testing
@testable import SSBNKClient

@Suite(.serialized)
struct CommandRunnerTests {
    @Test
    func testSSHAndWriteProbesUseExactBatchModeArgumentArrays() {
        XCTAssertEqual(
            SSBNKCommands.sshProbe(destination: "delorenj@big-chungus.burro-salmon.ts.net"),
            Command(
                executable: "/usr/bin/ssh",
                arguments: [
                    "-o", "BatchMode=yes",
                    "-o", "ConnectTimeout=10",
                    "delorenj@big-chungus.burro-salmon.ts.net",
                    "/usr/bin/true",
                ],
                timeout: 15
            )
        )
        XCTAssertEqual(
            SSBNKCommands.remoteWriteProbe(
                destination: "delorenj@big-chungus.burro-salmon.ts.net",
                directory: "/home/delorenj/Pictures/Screenshots"
            ).arguments,
            [
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=10",
                "delorenj@big-chungus.burro-salmon.ts.net",
                "/usr/bin/test", "-w", "/home/delorenj/Pictures/Screenshots",
            ]
        )
    }

    @Test
    func testRsyncUsesAtomicDefaultAndPreservesUnicodeLocalArgument() {
        let staged = URL(fileURLWithPath: "/tmp/Outbox/123/Screen Shot ünicode 1.png")
        let command = SSBNKCommands.rsync(
            stagedFile: staged,
            destination: "delorenj@big-chungus.burro-salmon.ts.net",
            remoteDirectory: "/home/delorenj/Pictures/Screenshots"
        )

        XCTAssertEqual(command.executable, "/usr/bin/rsync")
        XCTAssertEqual(command.arguments, [
            "--recursive",
            "--times",
            "--timeout=60",
            "--rsh=/usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=10",
            "--",
            "/tmp/Outbox/123/Screen Shot ünicode 1.png",
            "delorenj@big-chungus.burro-salmon.ts.net:/home/delorenj/Pictures/Screenshots/",
        ])
        XCTAssertFalse(command.arguments.contains("--inplace"))
        XCTAssertFalse(command.arguments.contains("--delete"))
        XCTAssertFalse(command.arguments.contains("--remove-source-files"))
    }

    @Test
    func testProcessRunnerDoesNotInvokeAShell() async throws {
        let result = try await ProcessCommandRunner().run(Command(
            executable: "/usr/bin/printf",
            arguments: ["%s", "spaces; $(not-a-command)"]
        ))

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardOutput, "spaces; $(not-a-command)")
    }

    @Test
    func testProcessRunnerTerminatesCommandAtDeadline() async throws {
        let started = Date()
        do {
            _ = try await ProcessCommandRunner().run(Command(
                executable: "/bin/sleep",
                arguments: ["5"],
                timeout: 0.05
            ))
            XCTFail("sleep should have timed out")
        } catch CommandRunnerError.timedOut(let seconds, _) {
            XCTAssertEqual(seconds, 0.05)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }
}
