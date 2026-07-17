import Foundation
import Testing
import XMtermCore
@testable import XMtermTerminal

@Suite("SSH terminal session", .serialized)
@MainActor
struct TerminalSessionSSHTests {
    @Test("[SESS-003, SESS-004] relay session launches the fixed direct OpenSSH contract")
    func launchUsesFixedRelayConfiguration() async throws {
        let launcher = RecordingTerminalProcessLauncher()
        let session = makeRelaySession(launcher: launcher)

        session.start()

        try await waitUntil { session.lifecycle == .running }
        let configuration = try #require(await launcher.configurations.first)
        #expect(session.kind == .relaySSH)
        #expect(configuration.executablePath == "/usr/bin/ssh")
        #expect(configuration.argumentZero == nil)
        #expect(configuration.arguments == ["-p", "54426", "allen921103@140.109.226.155"])
        #expect(configuration.environment["SSH_AUTH_SOCK"] == "/fixture/agent.sock")
        #expect(configuration.environment["SHELL"] == "/bin/zsh")
        #expect(configuration.workingDirectoryPath == "/fixture/home")
        try await closeAndVerifyNoInjectedInput(session, launcher: launcher)
    }

    @Test("[TAB-003] every live SSH session close requires confirmation without local-job probing")
    func liveSSHCloseAlwaysRequiresConfirmation() async throws {
        let launcher = RecordingTerminalProcessLauncher()
        let session = makeRelaySession(launcher: launcher)
        session.start()
        try await waitUntil { session.lifecycle == .running }

        #expect(await session.closeDisposition() == .confirmSSHSession)
        #expect(await launcher.process.foregroundQueryCount == 0)
        try await closeAndVerifyNoInjectedInput(session, launcher: launcher)
    }

    @Test("[TERM-STATE-001] final SSH output is retained before an honest exit status")
    func finalOutputPrecedesExitStateAndDisablesInput() async throws {
        let launcher = RecordingTerminalProcessLauncher()
        let session = makeRelaySession(launcher: launcher)
        session.start()
        try await waitUntil { session.lifecycle == .running }

        await launcher.process.finish(
            outputChunks: [Array("Permission denied\r\n".utf8)],
            status: .exited(code: 255)
        )

        try await waitUntil { session.lifecycle == .exited(.exited(code: 255)) }
        #expect(
            session.terminalView.getTerminal().getLine(row: 0)?.translateToString(trimRight: true)
                == "Permission denied"
        )
        #expect(!session.terminalView.acceptsInput)
        #expect(await session.closeDisposition() == .closeImmediately)
    }

    @Test("[TERM-STATE-001] relay launch failure becomes a typed failed state")
    func launchFailureIsTypedAndNonInteractive() async throws {
        let launcher = RecordingTerminalProcessLauncher(error: .launchFailed)
        let session = makeRelaySession(launcher: launcher)

        session.start()

        try await waitUntil {
            session.lifecycle == .failed(.launch(message: "The SSH process could not be launched."))
        }
        #expect(!session.terminalView.acceptsInput)
        #expect(await session.closeDisposition() == .closeImmediately)
    }

    @Test(
        "[TERM-STATE-001] normal and signal SSH exits remain exact",
        arguments: [
            TerminalExitStatus.exited(code: 0),
            .signaled(signal: 15)
        ]
    )
    func processExitStatusRemainsExact(_ status: TerminalExitStatus) async throws {
        let launcher = RecordingTerminalProcessLauncher()
        let session = makeRelaySession(launcher: launcher)
        session.start()
        try await waitUntil { session.lifecycle == .running }

        await launcher.process.finish(outputChunks: [], status: status)

        try await waitUntil { session.lifecycle == .exited(status) }
        #expect(!session.terminalView.acceptsInput)
    }

    @Test("[TERM-KEY-001, TERM-RESIZE-001] SSH shares terminal input and resize routing")
    func inputAndResizeUseTheSharedPTYPath() async throws {
        let launcher = RecordingTerminalProcessLauncher()
        let session = makeRelaySession(launcher: launcher)
        session.start()
        try await waitUntil { session.lifecycle == .running }
        let size = TerminalGridSize(columns: 132, rows: 43)

        session.terminalView.send([0x03, 0x0D])
        session.terminalView.onGridSizeChanged?(size)

        try await waitUntil {
            let writes = await launcher.process.writes
            let sizes = await launcher.process.sizes
            return writes == [[0x03, 0x0D]] && sizes.contains(size)
        }
        try await closeAndVerifyNoInjectedInput(session, launcher: launcher)
    }

    @Test("[TAB-005, TERM-STATE-001] an already-exited SSH child is never published as active")
    func immediateExitSkipsRunningStateAndRetainsFinalOutput() async throws {
        let launcher = RecordingTerminalProcessLauncher()
        await launcher.process.finish(
            outputChunks: [Array("Connection closed\r\n".utf8)],
            status: .exited(code: 255)
        )
        let session = makeRelaySession(launcher: launcher)
        var events: [TerminalLifecycleEvent] = []
        session.onLifecycleEvent = { event in
            events.append(event)
        }

        session.start()

        try await waitUntil { session.lifecycle == .exited(.exited(code: 255)) }
        #expect(events == [.startRequested, .processExited(.exited(code: 255))])
        #expect(!events.contains(.launchSucceeded))
        #expect(
            session.terminalView.getTerminal().getLine(row: 0)?.translateToString(trimRight: true)
                == "Connection closed"
        )
        #expect(!session.terminalView.acceptsInput)
    }

    @Test("[TAB-003, TERM-STATE-001] closing during delayed SSH launch cleans up without becoming active")
    func closeDuringDelayedLaunchNeverPublishesRunning() async throws {
        let launcher = DelayedTerminalProcessLauncher()
        let session = TerminalSession(
            id: UUID(),
            kind: .relaySSH,
            inheritedEnvironment: [:],
            userHomeDirectory: "/fixture/home",
            processLauncher: launcher.launch
        )
        var cleanupCount = 0
        var events: [TerminalLifecycleEvent] = []
        session.onCleanupFinished = { cleanupCount += 1 }
        session.onLifecycleEvent = { events.append($0) }

        session.start()
        try await waitUntil { await launcher.didReceiveLaunch }
        session.requestClose()
        #expect(session.lifecycle == .closing)

        await launcher.release()

        try await waitUntil {
            let closeCount = await launcher.process.closeCount
            return cleanupCount == 1 && closeCount == 1
        }
        #expect(!events.contains(.launchSucceeded))
        #expect(await launcher.process.writes.isEmpty)
    }

    @Test("[TERM-STATE-001] SSH read failure remains visible after deterministic cleanup")
    func readFailureIsTypedAndCleansUp() async throws {
        let launcher = RecordingTerminalProcessLauncher()
        let session = makeRelaySession(launcher: launcher)
        session.start()
        try await waitUntil { session.lifecycle == .running }

        await launcher.process.failRead()

        try await waitUntil {
            let closeCount = await launcher.process.closeCount
            return session.lifecycle == .failed(.read(message: "PTY output could not be read."))
                && closeCount == 1
        }
        #expect(!session.terminalView.acceptsInput)
    }

    @Test("[TERM-KEY-001, TERM-STATE-001] SSH write failure remains visible after cleanup")
    func writeFailureIsTypedAndCleansUp() async throws {
        let launcher = RecordingTerminalProcessLauncher()
        let session = makeRelaySession(launcher: launcher)
        session.start()
        try await waitUntil { session.lifecycle == .running }
        await launcher.process.failNextWrite()

        session.terminalView.send([0x61])

        try await waitUntil {
            let closeCount = await launcher.process.closeCount
            return session.lifecycle == .failed(.write(message: "PTY input could not be written."))
                && closeCount == 1
        }
        #expect(!session.terminalView.acceptsInput)
    }

    @Test("[TERM-RESIZE-001, TERM-STATE-001] SSH resize failure remains visible after cleanup")
    func resizeFailureIsTypedAndCleansUp() async throws {
        let launcher = RecordingTerminalProcessLauncher()
        let session = makeRelaySession(launcher: launcher)
        session.start()
        try await waitUntil { session.lifecycle == .running }
        try await waitUntil { !(await launcher.process.sizes).isEmpty }
        await launcher.process.failNextResize()

        session.terminalView.onGridSizeChanged?(
            TerminalGridSize(columns: 121, rows: 41)
        )

        try await waitUntil {
            let closeCount = await launcher.process.closeCount
            return session.lifecycle == .failed(.resize(message: "The PTY window size could not be updated."))
                && closeCount == 1
        }
        #expect(!session.terminalView.acceptsInput)
    }

    private func makeRelaySession(
        launcher: RecordingTerminalProcessLauncher
    ) -> TerminalSession {
        TerminalSession(
            id: UUID(),
            kind: .relaySSH,
            inheritedEnvironment: [
                "SHELL": "/bin/zsh",
                "SSH_AUTH_SOCK": "/fixture/agent.sock"
            ],
            userHomeDirectory: "/fixture/home",
            processLauncher: launcher.launch
        )
    }

    private func closeAndVerifyNoInjectedInput(
        _ session: TerminalSession,
        launcher: RecordingTerminalProcessLauncher
    ) async throws {
        let writesBeforeClose = await launcher.process.writes

        session.requestClose()

        try await waitUntil {
            await launcher.process.closeCount == 1
                && session.lifecycle == .exited(.signaled(signal: SIGTERM))
        }
        #expect(await launcher.process.closeCount == 1)
        #expect(await launcher.process.writes == writesBeforeClose)
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        _ condition: @escaping @MainActor () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .nanoseconds(Int64(timeoutNanoseconds)))
        while !(await condition()) {
            guard clock.now < deadline else {
                Issue.record("Timed out waiting for SSH session state")
                return
            }
            await Task.yield()
        }
    }
}
