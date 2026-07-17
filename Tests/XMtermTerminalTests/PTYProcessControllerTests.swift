import Darwin
import Foundation
import Testing
import XMtermCore
@testable import XMtermTerminal

@Suite("PTY process controller", .serialized)
struct PTYProcessControllerTests {
    @Test("[TERM-KEY-001] /bin/cat round-trips exact bytes", .timeLimit(.minutes(1)))
    func catRoundTripsExactBytes() async throws {
        let marker = "XMTERM_CAT_READY"
        let controller = try await PTYProcessController.launch(rawCatConfiguration(marker: marker))

        do {
            _ = try await withTimeout {
                try await readUntil(Array(marker.utf8), from: controller)
            }

            let payload = Array("XMterm 測試\n".utf8) + [0x00, 0x03, 0x7F, 0x80, 0xFF]
            try await controller.write(payload)

            let echoed = try await withTimeout {
                try await readExactly(payload.count, from: controller)
            }
            #expect(echoed == payload)

            _ = try await withTimeout { try await controller.close() }
        } catch {
            _ = try? await controller.close()
            throw error
        }
    }

    @Test("[TERM-RESIZE-001] resize changes the PTY kernel window size", .timeLimit(.minutes(1)))
    func resizeIsReflectedBySttySize() async throws {
        let marker = "XMTERM_RESIZE_READY"
        let script = #"/bin/stty raw -echo && /usr/bin/printf "%s" "$XMTERM_TEST_MARKER" && IFS= read -r _ && /bin/stty size"#
        let controller = try await PTYProcessController.launch(
            configuration(
                arguments: ["-c", script],
                environment: fixtureEnvironment(marker: marker)
            )
        )

        do {
            _ = try await withTimeout {
                try await readUntil(Array(marker.utf8), from: controller)
            }

            try await controller.resize(to: TerminalGridSize(columns: 101, rows: 37))
            try await controller.write([0x0A])

            let output = try await withTimeout {
                try await readToEOF(from: controller)
            }
            let fields = String(decoding: output, as: UTF8.self)
                .split(whereSeparator: \Character.isWhitespace)
                .map(String.init)
            #expect(fields == ["37", "101"])
            #expect(try await controller.waitForExit() == .exited(code: 0))

            _ = try await controller.close()
        } catch {
            _ = try? await controller.close()
            throw error
        }
    }

    @Test("[TERM-STATE-001] normal child exit preserves its status", .timeLimit(.minutes(1)))
    func normalExitCodeIsReturned() async throws {
        let controller = try await PTYProcessController.launch(
            configuration(arguments: ["-c", "exit 23"])
        )

        let status = try await withTimeout { try await controller.waitForExit() }
        #expect(status == .exited(code: 23))
        #expect(try await controller.close() == status)
    }

    @Test("[TERM-STATE-001] signal termination preserves the signal", .timeLimit(.minutes(1)))
    func signalExitIsReturned() async throws {
        let controller = try await PTYProcessController.launch(
            configuration(executablePath: "/bin/sleep", arguments: ["30"])
        )
        #expect(Darwin.kill(controller.processIdentifier, SIGKILL) == 0)

        let status = try await withTimeout { try await controller.waitForExit() }
        #expect(status == .signaled(signal: SIGKILL))
        #expect(try await controller.close() == status)
    }

    @Test("[TERM-STATE-001] final output reaches EOF before exit completion", .timeLimit(.minutes(1)))
    func finalOutputAndEOFReconcileWithExitStatus() async throws {
        let controller = try await PTYProcessController.launch(
            configuration(arguments: ["-c", #"/usr/bin/printf "final-output"; exit 9"#])
        )

        do {
            let output = try await withTimeout {
                try await readToEOF(from: controller)
            }
            let status = try await withTimeout { try await controller.waitForExit() }

            #expect(output == Array("final-output".utf8))
            #expect(status == .exited(code: 9))
            #expect(try await controller.close() == status)
        } catch {
            _ = try? await controller.close()
            throw error
        }
    }

    @Test("Draining close preserves output across the controller boundary", .timeLimit(.minutes(1)))
    func closeDrainsBufferedFinalOutput() async throws {
        let outputByteCount = 128 * 1024
        let controller = try await PTYProcessController.launch(
            configuration(
                arguments: [
                    "-c",
                    "trap '' HUP TERM; exec /usr/bin/head -c \(outputByteCount) /dev/zero"
                ]
            )
        )

        try await Task.sleep(for: .milliseconds(200))

        let closeTask = Task {
            try await controller.close(outputPolicy: .drain)
        }
        try await Task.sleep(for: .milliseconds(10))

        let output = try await withTimeout {
            try await readToEOF(from: controller, outputLimit: outputByteCount)
        }
        let status = try await withTimeout {
            try await closeTask.value
        }

        #expect(output.count == outputByteCount)
        #expect(output.allSatisfy { $0 == 0 })
        #expect(status == .exited(code: 0))
    }

    @Test("A reaped direct child cannot be held open by a descendant", .timeLimit(.minutes(1)))
    func descendantHoldingSlaveCannotPreventExitCompletion() async throws {
        let marker = "XMTERM_DESCENDANT_READY"
        let script = #"trap '' HUP; /bin/sleep 30 & descendant=$!; /usr/bin/printf "%s:%s:END" "$XMTERM_TEST_MARKER" "$descendant"; exit 17"#
        let controller = try await PTYProcessController.launch(
            configuration(
                arguments: ["-c", script],
                environment: fixtureEnvironment(marker: marker)
            )
        )

        let startupOutput = try await withTimeout {
            try await readUntil(Array(":END".utf8), from: controller)
        }
        let descendantProcessIdentifier = try parseProcessIdentifier(
            from: startupOutput,
            marker: marker
        )
        defer {
            _ = Darwin.kill(descendantProcessIdentifier, SIGKILL)
        }

        let status = try await withTimeout(.seconds(2)) {
            try await controller.waitForExit()
        }

        #expect(status == .exited(code: 17))
        #expect(
            Darwin.kill(descendantProcessIdentifier, 0) == 0,
            "The fixture descendant must still be alive when the direct child completes"
        )
        #expect(try await controller.close() == status)
    }

    @Test("Launch preserves an explicit login-shell argv[0]", .timeLimit(.minutes(1)))
    func explicitArgumentZeroIsPreserved() async throws {
        let script = #"/usr/bin/printf "%s" "$0""#
        let controller = try await PTYProcessController.launch(
            configuration(
                argumentZero: "-xmterm-test-sh",
                arguments: ["-c", script]
            )
        )

        do {
            let output = try await withTimeout {
                try await readToEOF(from: controller)
            }
            #expect(output == Array("-xmterm-test-sh".utf8))
            #expect(try await controller.waitForExit() == .exited(code: 0))
            _ = try await controller.close()
        } catch {
            _ = try? await controller.close()
            throw error
        }
    }

    @Test("[TERM-PROC-001] close is idempotent and reaps the child", .timeLimit(.minutes(1)))
    func closeReapsChildWithoutLeavingAZombie() async throws {
        let marker = "XMTERM_REAP_READY"
        let script = #"set -m; /bin/sleep 30 & job=$!; /usr/bin/printf "%s:%s:END" "$XMTERM_TEST_MARKER" "$job"; fg"#
        let controller = try await PTYProcessController.launch(
            configuration(
                arguments: ["-c", script],
                environment: fixtureEnvironment(marker: marker)
            )
        )

        let startupOutput = try await withTimeout {
            try await readUntil(Array(":END".utf8), from: controller)
        }
        let foregroundProcessIdentifier = try parseProcessIdentifier(
            from: startupOutput,
            marker: marker
        )
        let processIdentifier = controller.processIdentifier

        let firstStatus = try await withTimeout { try await controller.close() }
        let repeatedStatus = try await controller.close()
        let waitedStatus = try await controller.waitForExit()

        #expect(repeatedStatus == firstStatus)
        #expect(waitedStatus == firstStatus)

        var rawStatus: Int32 = 0
        let waitResult = Darwin.waitpid(processIdentifier, &rawStatus, WNOHANG)
        if waitResult == -1 {
            #expect(errno == ECHILD)
        } else {
            Issue.record("Expected the PTY controller to reap child \(processIdentifier); waitpid returned \(waitResult)")
        }

        let foregroundResult = Darwin.kill(foregroundProcessIdentifier, 0)
        if foregroundResult == -1 {
            #expect(errno == ESRCH)
        } else {
            Issue.record(
                "Expected close() to terminate foreground process \(foregroundProcessIdentifier); kill(pid, 0) returned \(foregroundResult)"
            )
        }
    }

    @Test(
        "[TAB-003, TERM-PROC-001] foreground process groups distinguish an idle shell from a job",
        .timeLimit(.minutes(1))
    )
    func foregroundProcessGroupsTrackShellJobControl() async throws {
        let marker = "XMTERM_CLOSE_PROMPT> "
        let controller = try await PTYProcessController.launch(
            interactiveShellConfiguration(prompt: marker)
        )

        do {
            _ = try await withTimeout {
                try await readUntil(Array(marker.utf8), from: controller)
            }

            #expect(controller.shellProcessIdentifier == controller.processIdentifier)
            #expect(
                controller.shellProcessGroupIdentifier
                    == Darwin.getpgid(controller.shellProcessIdentifier)
            )
            #expect(await controller.foregroundProcessGroupState() == .shell)

            try await controller.write(Array("/bin/sleep 30\n".utf8))
            try await waitForForegroundState(.foregroundJob, from: controller)

            try await controller.write([0x03])
            _ = try await withTimeout {
                try await readUntil(Array(marker.utf8), from: controller)
            }
            try await waitForForegroundState(.shell, from: controller)

            try await controller.write(Array("/bin/sleep 0.1\n".utf8))
            _ = try await withTimeout {
                try await readUntil(Array(marker.utf8), from: controller)
            }
            try await waitForForegroundState(.shell, from: controller)

            try await controller.write(Array("cd /; pwd; echo XMTERM_DONE\n".utf8))
            _ = try await withTimeout {
                try await readUntil(Array(marker.utf8), from: controller)
            }
            try await waitForForegroundState(.shell, from: controller)

            try await controller.write(Array("/bin/sleep 30 | /bin/cat\n".utf8))
            try await waitForForegroundState(.foregroundJob, from: controller)
            try await controller.write([0x03])
            _ = try await withTimeout {
                try await readUntil(Array(marker.utf8), from: controller)
            }
            try await waitForForegroundState(.shell, from: controller)

            try await controller.write(Array("/bin/sleep 30 &\n".utf8))
            _ = try await withTimeout {
                try await readUntil(Array(marker.utf8), from: controller)
            }
            try await waitForForegroundState(.shell, from: controller)

            try await controller.write(Array("kill %1\n".utf8))
            _ = try await withTimeout {
                try await readUntil(Array(marker.utf8), from: controller)
            }
            _ = try await controller.close()
        } catch {
            _ = try? await controller.close()
            throw error
        }
    }

    @Test("[TAB-003] closed PTYs and query failures remain distinct", .timeLimit(.minutes(1)))
    func unavailableAndFailedForegroundQueriesAreTyped() async throws {
        #expect(
            PTYProcessController.classifyForegroundProcessGroup(
                queryResult: -1,
                shellProcessGroupIdentifier: 42,
                errorNumber: EIO
            ) == .queryFailed(errorNumber: EIO)
        )

        let controller = try await PTYProcessController.launch(
            configuration(executablePath: "/bin/sleep", arguments: ["30"])
        )
        _ = try await controller.close()

        #expect(await controller.foregroundProcessGroupState() == .terminalUnavailable)
    }

    @Test("[TERM-PROC-001] close escalation treats a missing group as gone but reports signal denial")
    func closeEscalationSignalErrorsAreTyped() {
        #expect(
            PTYProcessController.closeSignalFailure(
                errorNumber: ESRCH,
                signalNumber: SIGTERM
            ) == nil
        )
        #expect(
            PTYProcessController.closeSignalFailure(
                errorNumber: EPERM,
                signalNumber: SIGTERM
            ) == .processGroupSignalFailed(signal: SIGTERM, errno: EPERM)
        )
        #expect(
            !PTYProcessController.canSurfaceCloseFailure(
                childWasReaped: false,
                childCleanupTimedOut: false
            )
        )
        #expect(
            PTYProcessController.canSurfaceCloseFailure(
                childWasReaped: true,
                childCleanupTimedOut: false
            )
        )
        #expect(
            PTYProcessController.canSurfaceCloseFailure(
                childWasReaped: false,
                childCleanupTimedOut: true
            )
        )
        #expect(
            PTYProcessController.prioritizedCloseFailure(
                current: .processGroupSignalFailed(signal: SIGKILL, errno: EPERM),
                new: .childProcessStillRunning
            ) == .childProcessStillRunning
        )
        #expect(
            PTYProcessController.prioritizedCloseFailure(
                current: .childProcessStillRunning,
                new: .foregroundProcessCleanupUnverifiable
            ) == .childProcessStillRunning
        )
    }

    @Test("[TERM-PROC-001] close escalates a signal-ignoring foreground job", .timeLimit(.minutes(1)))
    func closeEscalatesSignalIgnoringForegroundJob() async throws {
        let marker = "XMTERM_STUBBORN_FOREGROUND"
        let script = #"set -m; /bin/sh -c 'trap "" HUP TERM; exec /bin/sleep 30' & job=$!; /usr/bin/printf "%s:%s:END" "$XMTERM_TEST_MARKER" "$job"; fg"#
        let controller = try await PTYProcessController.launch(
            configuration(
                arguments: ["-c", script],
                environment: fixtureEnvironment(marker: marker)
            )
        )
        let startupOutput = try await withTimeout {
            try await readUntil(Array(":END".utf8), from: controller)
        }
        let foregroundProcessIdentifier = try parseProcessIdentifier(
            from: startupOutput,
            marker: marker
        )

        _ = try await withTimeout { try await controller.close() }

        let result = Darwin.kill(foregroundProcessIdentifier, 0)
        #expect(result == -1)
        #expect(errno == ESRCH)
    }

    @Test("[TAB-003] two controllers own independent child processes", .timeLimit(.minutes(1)))
    func twoProcessesHaveIndependentIdentityAndLifetime() async throws {
        let firstMarker = "XMTERM_FIRST_READY"
        let secondMarker = "XMTERM_SECOND_READY"
        let first = try await PTYProcessController.launch(rawCatConfiguration(marker: firstMarker))

        do {
            let second = try await PTYProcessController.launch(rawCatConfiguration(marker: secondMarker))

            do {
                #expect(first.processIdentifier != second.processIdentifier)
                _ = try await withTimeout {
                    try await readUntil(Array(firstMarker.utf8), from: first)
                }
                _ = try await withTimeout {
                    try await readUntil(Array(secondMarker.utf8), from: second)
                }

                _ = try await first.close()

                let payload = Array("second-still-running".utf8)
                try await second.write(payload)
                let echoed = try await withTimeout {
                    try await readExactly(payload.count, from: second)
                }
                #expect(echoed == payload)

                _ = try await second.close()
            } catch {
                _ = try? await first.close()
                _ = try? await second.close()
                throw error
            }
        } catch {
            _ = try? await first.close()
            throw error
        }
    }

    @Test("Launch validation reports an exact relative-executable error")
    func relativeExecutablePathIsRejectedDeterministically() async {
        let invalid = configuration(executablePath: "bin/cat")

        do {
            let controller = try await PTYProcessController.launch(invalid)
            _ = try? await controller.close()
            Issue.record("Expected a relative executable path to be rejected")
        } catch {
            #expect(
                error as? PTYControllerError
                    == .executablePathMustBeAbsolute("bin/cat")
            )
        }
    }

    @Test("Launch validation reports an exact embedded-NUL error")
    func embeddedNULArgumentIsRejectedDeterministically() async {
        let invalid = configuration(arguments: ["valid", "invalid\0argument"])

        do {
            let controller = try await PTYProcessController.launch(invalid)
            _ = try? await controller.close()
            Issue.record("Expected an argument containing NUL to be rejected")
        } catch {
            #expect(error as? PTYControllerError == .argumentContainsNUL(index: 1))
        }
    }

    @Test("Launch validation rejects NUL in an explicit argv[0]")
    func embeddedNULArgumentZeroIsRejectedDeterministically() async {
        let invalid = configuration(argumentZero: "-bad\0shell")

        do {
            let controller = try await PTYProcessController.launch(invalid)
            _ = try? await controller.close()
            Issue.record("Expected argv[0] containing NUL to be rejected")
        } catch {
            #expect(error as? PTYControllerError == .argumentZeroContainsNUL)
        }
    }

    @Test("Launch validation rejects malformed path and environment boundaries")
    func malformedLaunchBoundariesAreRejectedDeterministically() async {
        let cases: [(PTYLaunchConfiguration, PTYControllerError)] = [
            (
                configuration(executablePath: "/bin/cat\0hidden"),
                .executablePathContainsNUL
            ),
            (
                configuration(workingDirectoryPath: "relative"),
                .workingDirectoryPathMustBeAbsolute("relative")
            ),
            (
                configuration(workingDirectoryPath: "/tmp\0hidden"),
                .workingDirectoryPathContainsNUL
            ),
            (
                configuration(environment: ["": "value"]),
                .invalidEnvironmentKey("")
            ),
            (
                configuration(environment: ["BAD=KEY": "value"]),
                .invalidEnvironmentKey("BAD=KEY")
            ),
            (
                configuration(environment: ["KEY": "bad\0value"]),
                .environmentValueContainsNUL(key: "KEY")
            )
        ]

        for (invalid, expectedError) in cases {
            do {
                let controller = try await PTYProcessController.launch(invalid)
                _ = try? await controller.close()
                Issue.record("Expected malformed launch configuration to be rejected")
            } catch {
                #expect(error as? PTYControllerError == expectedError)
            }
        }
    }

    @Test("Child exec failure reports startup errno through the PTY shim")
    func missingAbsoluteExecutableReportsENOENT() async {
        let missing = configuration(executablePath: "/xmterm-fixture/missing-executable")

        do {
            let controller = try await PTYProcessController.launch(missing)
            _ = try? await controller.close()
            Issue.record("Expected the missing executable to fail before launch completion")
        } catch {
            #expect(error as? PTYControllerError == .launchFailed(errno: ENOENT))
        }
    }

    @Test("Ordered writes enforce the bounded paste-sized queue", .timeLimit(.minutes(1)))
    func oversizedWriteIsRejectedDeterministically() async throws {
        let marker = "XMTERM_WRITE_LIMIT_READY"
        let controller = try await PTYProcessController.launch(rawCatConfiguration(marker: marker))

        do {
            _ = try await withTimeout {
                try await readUntil(Array(marker.utf8), from: controller)
            }

            let oversized = [UInt8](
                repeating: 0x41,
                count: TerminalConfiguration.pasteByteLimit + 1
            )
            do {
                try await controller.write(oversized)
                Issue.record("Expected the bounded write queue to reject an oversized payload")
            } catch {
                #expect(
                    error as? PTYControllerError
                        == .pendingWriteLimitExceeded(limit: TerminalConfiguration.pasteByteLimit)
                )
            }

            _ = try await controller.close()
        } catch {
            _ = try? await controller.close()
            throw error
        }
    }

    @Test("Closed PTYs reject input and resize while reads remain at EOF", .timeLimit(.minutes(1)))
    func operationsAfterCloseAreDeterministic() async throws {
        let controller = try await PTYProcessController.launch(
            configuration(arguments: ["-c", "exit 0"])
        )
        _ = try await withTimeout { try await controller.waitForExit() }

        do {
            try await controller.write([0x41])
            Issue.record("Expected writing a closed PTY to fail")
        } catch {
            #expect(error as? PTYControllerError == .closed)
        }

        do {
            try await controller.resize(to: TerminalGridSize(columns: 90, rows: 30))
            Issue.record("Expected resizing a closed PTY to fail")
        } catch {
            #expect(error as? PTYControllerError == .closed)
        }

        #expect(try await controller.read(upToCount: 1) == nil)

        do {
            _ = try await controller.read(upToCount: 0)
            Issue.record("Expected a non-positive read size to fail")
        } catch {
            #expect(error as? PTYControllerError == .invalidReadByteCount(0))
        }
    }
}

private func configuration(
    executablePath: String = "/bin/sh",
    argumentZero: String? = nil,
    arguments: [String] = [],
    environment: [String: String] = fixtureEnvironment(),
    workingDirectoryPath: String = "/",
    initialSize: TerminalGridSize = TerminalGridSize(columns: 80, rows: 24)
) -> PTYLaunchConfiguration {
    PTYLaunchConfiguration(
        executablePath: executablePath,
        argumentZero: argumentZero,
        arguments: arguments,
        environment: environment,
        workingDirectoryPath: workingDirectoryPath,
        initialSize: initialSize
    )
}

private func rawCatConfiguration(marker: String) -> PTYLaunchConfiguration {
    let script = #"/bin/stty raw -echo && /usr/bin/printf "%s" "$XMTERM_TEST_MARKER" && exec /bin/cat"#
    return configuration(
        arguments: ["-c", script],
        environment: fixtureEnvironment(marker: marker)
    )
}

private func interactiveShellConfiguration(prompt: String) -> PTYLaunchConfiguration {
    configuration(
        executablePath: "/bin/zsh",
        argumentZero: "zsh",
        arguments: ["-f"],
        environment: fixtureEnvironment().merging(
            [
                "HOME": "/tmp",
                "PROMPT": prompt,
                "PS1": prompt,
                "TERM": "xterm-256color"
            ],
            uniquingKeysWith: { _, fixtureValue in fixtureValue }
        ),
        workingDirectoryPath: "/tmp"
    )
}

private func fixtureEnvironment(marker: String? = nil) -> [String: String] {
    var environment = [
        "LC_ALL": "C",
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"
    ]
    if let marker {
        environment["XMTERM_TEST_MARKER"] = marker
    }
    return environment
}

private func readUntil(
    _ expected: [UInt8],
    from controller: PTYProcessController,
    outputLimit: Int = 64 * 1024
) async throws -> [UInt8] {
    var output: [UInt8] = []

    while Data(output).range(of: Data(expected)) == nil {
        guard let chunk = try await controller.read(upToCount: 4 * 1024) else {
            throw PTYTestFixtureError.unexpectedEOF
        }
        output.append(contentsOf: chunk)
        guard output.count <= outputLimit else {
            throw PTYTestFixtureError.outputLimitExceeded
        }
    }

    return output
}

private func waitForForegroundState(
    _ expected: PTYForegroundProcessGroupState,
    from controller: PTYProcessController
) async throws {
    try await withTimeout(.seconds(5)) {
        while await controller.foregroundProcessGroupState() != expected {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private func parseProcessIdentifier(
    from output: [UInt8],
    marker: String
) throws -> pid_t {
    let text = String(decoding: output, as: UTF8.self)
    guard let markerRange = text.range(of: "\(marker):"),
          let terminatorRange = text.range(
              of: ":END",
              range: markerRange.upperBound ..< text.endIndex
          ),
          let processIdentifier = pid_t(text[markerRange.upperBound ..< terminatorRange.lowerBound]),
          processIdentifier > 0 else {
        throw PTYTestFixtureError.invalidProcessIdentifierOutput(text)
    }
    return processIdentifier
}

private func readExactly(
    _ byteCount: Int,
    from controller: PTYProcessController
) async throws -> [UInt8] {
    var output: [UInt8] = []

    while output.count < byteCount {
        guard let chunk = try await controller.read(upToCount: byteCount - output.count) else {
            throw PTYTestFixtureError.unexpectedEOF
        }
        output.append(contentsOf: chunk)
    }

    return output
}

private func readToEOF(
    from controller: PTYProcessController,
    outputLimit: Int = 64 * 1024
) async throws -> [UInt8] {
    var output: [UInt8] = []

    while let chunk = try await controller.read(upToCount: 4 * 1024) {
        output.append(contentsOf: chunk)
        guard output.count <= outputLimit else {
            throw PTYTestFixtureError.outputLimitExceeded
        }
    }

    return output
}

private func withTimeout<Value: Sendable>(
    _ duration: Duration = .seconds(10),
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(for: duration)
            throw PTYTestFixtureError.timedOut
        }

        guard let firstResult = try await group.next() else {
            throw PTYTestFixtureError.missingTaskResult
        }
        group.cancelAll()
        return firstResult
    }
}

private enum PTYTestFixtureError: Error {
    case unexpectedEOF
    case outputLimitExceeded
    case timedOut
    case missingTaskResult
    case invalidProcessIdentifierOutput(String)
}
