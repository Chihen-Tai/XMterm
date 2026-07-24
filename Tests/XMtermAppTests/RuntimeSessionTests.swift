import Foundation
import Testing
import XMtermCore
import XMtermRemote
import XMtermTerminal
@testable import XMtermApp

@Suite("Runtime session composition", .serialized)
@MainActor
struct RuntimeSessionTests {
    @Test("[SESS-011, FILE-WORKSPACE-001] target eligibility owns exactly one capability set")
    func targetEligibility() throws {
        let local = SessionLaunchSpecification.legacy(kind: .local, title: "Local")
        let localTerminal = makeTerminal(specification: local)
        let localRuntime = try RuntimeSession(
            id: localTerminal.sessionID,
            launchSpecification: local,
            terminal: localTerminal,
            remoteWorkspace: nil
        )
        #expect(localRuntime.remoteWorkspace == nil)

        let ssh = SessionLaunchSpecification.legacy(kind: .relaySSH, title: "SSH")
        let sshTerminal = makeTerminal(specification: ssh)
        let workspace = RemoteWorkspace(
            runtimeID: sshTerminal.sessionID,
            provider: RuntimeSessionTestRemoteFileProvider()
        )
        #expect(throws: RuntimeSessionCompositionError.workspaceEligibilityMismatch) {
            try RuntimeSession(
                id: localTerminal.sessionID,
                launchSpecification: local,
                terminal: localTerminal,
                remoteWorkspace: workspace
            )
        }

        let sshRuntime = try RuntimeSession(
            id: sshTerminal.sessionID,
            launchSpecification: ssh,
            terminal: sshTerminal,
            remoteWorkspace: workspace
        )
        #expect(sshRuntime.remoteWorkspace === workspace)
        #expect(throws: RuntimeSessionCompositionError.workspaceEligibilityMismatch) {
            try RuntimeSession(
                id: sshTerminal.sessionID,
                launchSpecification: ssh,
                terminal: sshTerminal,
                remoteWorkspace: nil
            )
        }
    }

    @Test("[SESS-007, SESS-011] terminal identity and launch snapshot are exact")
    func terminalContractIsExact() {
        let specification = SessionLaunchSpecification.legacy(kind: .local, title: "Local")
        let terminal = makeTerminal(specification: specification)

        #expect(throws: RuntimeSessionCompositionError.terminalContractViolation) {
            try RuntimeSession(
                id: TerminalSessionID(),
                launchSpecification: specification,
                terminal: terminal,
                remoteWorkspace: nil
            )
        }

        let other = SessionLaunchSpecification.legacy(kind: .local, title: "Other")
        #expect(throws: RuntimeSessionCompositionError.terminalContractViolation) {
            try RuntimeSession(
                id: terminal.sessionID,
                launchSpecification: other,
                terminal: terminal,
                remoteWorkspace: nil
            )
        }
    }

    @Test("[SESS-007, SESS-011] a pre-settled terminal cannot be composed")
    func preSettledTerminalIsRejected() {
        let specification = SessionLaunchSpecification.legacy(kind: .local, title: "Local")
        let terminal = makeTerminal(specification: specification)
        terminal.requestClose()

        #expect(terminal.lifecycle != .idle)
        #expect(throws: RuntimeSessionCompositionError.terminalContractViolation) {
            try RuntimeSession(
                id: terminal.sessionID,
                launchSpecification: specification,
                terminal: terminal,
                remoteWorkspace: nil
            )
        }
    }

    @Test("[SESS-011] start launches terminal and workspace once")
    func startIsIndependentAndIdempotent() async throws {
        let provider = RuntimeSessionTestRemoteFileProvider()
        let process = RuntimeSessionTestTerminalProcess()
        let probe = RuntimeSessionTestLaunchProbe()
        let runtime = try makeSSHRuntime(provider: provider, process: process, probe: probe)

        runtime.start()
        runtime.start()

        try await eventually {
            let launchCount = await probe.count()
            let providerSnapshot = await provider.snapshot()
            return launchCount == 1
                && providerSnapshot.resolveCount == 1
                && runtime.terminal.lifecycle == .running
                && runtime.remoteWorkspace?.availability == .available
        }
        runtime.requestClose()
        try await eventually { await process.recordedCloseCount() == 1 }
    }

    @Test("[SESS-006, SESS-011] workspace failure does not change terminal lifecycle")
    func workspaceFailureIsIsolated() async throws {
        let provider = RuntimeSessionTestRemoteFileProvider(
            resolveFailure: RemoteFileError(category: .transportUnavailable)
        )
        let process = RuntimeSessionTestTerminalProcess()
        let runtime = try makeSSHRuntime(provider: provider, process: process)
        var cleanupCount = 0
        runtime.onCleanupFinished = { cleanupCount += 1 }

        runtime.start()

        try await eventually {
            runtime.terminal.lifecycle == .running
                && runtime.remoteWorkspace?.availability
                    == .failed(RemoteFileError(category: .transportUnavailable))
        }
        #expect(cleanupCount == 0)
        runtime.requestClose()
        try await eventually { cleanupCount == 1 }
    }

    @Test("[SESS-006, SESS-011] aggregate cleanup waits for terminal after workspace")
    func closeWaitsForTerminal() async throws {
        let provider = RuntimeSessionTestRemoteFileProvider()
        let process = RuntimeSessionTestTerminalProcess(suspendsClose: true)
        let runtime = try makeSSHRuntime(provider: provider, process: process)
        var cleanupCount = 0
        runtime.onCleanupFinished = { cleanupCount += 1 }
        runtime.start()
        try await eventually { runtime.terminal.lifecycle == .running }

        runtime.requestClose()
        runtime.requestClose()
        try await eventually {
            let providerSnapshot = await provider.snapshot()
            let terminalCloseCount = await process.recordedCloseCount()
            return providerSnapshot.closeCount == 1 && terminalCloseCount == 1
        }
        #expect(cleanupCount == 0)

        await process.releaseClose()
        try await eventually { cleanupCount == 1 }
        runtime.requestClose()
        #expect(cleanupCount == 1)
        #expect(await provider.snapshot().cancelAllCount == 1)
        #expect(await provider.snapshot().closeCount == 1)
        #expect(await process.recordedCloseCount() == 1)
    }

    @Test("[SESS-006, SESS-011] aggregate cleanup waits for workspace after terminal")
    func closeWaitsForWorkspace() async throws {
        let provider = RuntimeSessionTestRemoteFileProvider(suspendsClose: true)
        let process = RuntimeSessionTestTerminalProcess()
        let runtime = try makeSSHRuntime(provider: provider, process: process)
        var cleanupCount = 0
        runtime.onCleanupFinished = { cleanupCount += 1 }
        runtime.start()
        try await eventually { runtime.terminal.lifecycle == .running }

        runtime.requestClose()
        try await eventually {
            let providerSnapshot = await provider.snapshot()
            let terminalCloseCount = await process.recordedCloseCount()
            return providerSnapshot.closeCount == 1 && terminalCloseCount == 1
        }
        #expect(cleanupCount == 0)

        await provider.releaseClose()
        try await eventually { cleanupCount == 1 }
    }

    @Test("[SESS-011] close before start cannot resurrect either capability")
    func closeBeforeStart() async throws {
        let provider = RuntimeSessionTestRemoteFileProvider()
        let process = RuntimeSessionTestTerminalProcess()
        let probe = RuntimeSessionTestLaunchProbe()
        let runtime = try makeSSHRuntime(provider: provider, process: process, probe: probe)
        var cleanupCount = 0
        runtime.onCleanupFinished = { cleanupCount += 1 }

        runtime.requestClose()
        runtime.start()

        try await eventually { cleanupCount == 1 }
        #expect(await probe.count() == 0)
        #expect(await provider.snapshot().resolveCount == 0)
        #expect(await provider.snapshot().closeCount == 1)
    }

    private func makeSSHRuntime(
        provider: RuntimeSessionTestRemoteFileProvider,
        process: RuntimeSessionTestTerminalProcess,
        probe: RuntimeSessionTestLaunchProbe = RuntimeSessionTestLaunchProbe()
    ) throws -> RuntimeSession {
        let specification = SessionLaunchSpecification.legacy(kind: .relaySSH, title: "SSH")
        let terminal = makeTerminal(
            specification: specification,
            process: process,
            probe: probe
        )
        return try RuntimeSession(
            id: terminal.sessionID,
            launchSpecification: specification,
            terminal: terminal,
            remoteWorkspace: RemoteWorkspace(
                runtimeID: terminal.sessionID,
                provider: provider
            )
        )
    }

    private func makeTerminal(
        specification: SessionLaunchSpecification,
        process: RuntimeSessionTestTerminalProcess = RuntimeSessionTestTerminalProcess(),
        probe: RuntimeSessionTestLaunchProbe = RuntimeSessionTestLaunchProbe()
    ) -> TerminalSession {
        TerminalSession(
            sessionID: TerminalSessionID(),
            launchSpecification: specification,
            configurationFactory: SessionLaunchConfigurationFactory(
                inheritedEnvironment: [:],
                userHomeDirectory: "/fixture/home",
                loginShellResolver: {
                    ResolvedTerminalShell(
                        executablePath: "/bin/zsh",
                        argumentZero: "-zsh",
                        arguments: [],
                        workingDirectory: "/fixture/home"
                    )
                },
                isUsableExecutableFile: { _ in true }
            ),
            processLauncher: { _ in
                await probe.recordLaunch()
                return process
            }
        )
    }

    private func eventually(
        _ condition: @escaping @MainActor () async -> Bool
    ) async throws {
        for _ in 0..<1_000 {
            if await condition() { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for deterministic runtime state")
    }
}
