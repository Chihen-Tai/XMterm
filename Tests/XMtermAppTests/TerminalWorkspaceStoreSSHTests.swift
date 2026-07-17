import Foundation
import Testing
import XMtermCore
import XMtermTerminal
@testable import XMtermApp

@Suite("SSH workspace coordination", .serialized)
@MainActor
struct TerminalWorkspaceStoreSSHTests {
    @Test("[TAB-001, TAB-002, SESS-002] local and fixed relay tabs coexist and select independently")
    func createsAndSelectsFixedRelayTab() async throws {
        let relayProcess = WorkspaceTestTerminalProcess()
        let store = makeStore(relayProcess: relayProcess)
        store.startIfNeeded()
        try await waitUntil { store.tabs.first?.lifecycle == .running }
        let localID = try #require(store.tabs.first?.id)

        store.createSSHTerminal()

        try await waitUntil { store.tabs.count == 2 && store.selectedTab?.kind == .relaySSH }
        let relayTab = try #require(store.selectedTab)
        #expect(store.tabs.map(\.kind) == [.local, .relaySSH])
        #expect(store.tabs.map(\.title) == ["Local Shell", "Relay Host"])
        #expect(store.sessions[localID]?.kind == .local)
        #expect(store.sessions[relayTab.id]?.kind == .relaySSH)

        store.sessions[relayTab.id]?.terminalView.onTitleChanged?("untrusted remote title")
        #expect(store.tabs.first(where: { $0.id == relayTab.id })?.title == "Relay Host")

        store.selectTab(localID)
        #expect(store.selectedTab?.id == localID)
        store.cleanupAllSessions()
        try await waitUntil { store.sessions.isEmpty }
    }

    @Test("[TAB-003] closing a live relay tab always presents the SSH-specific decision")
    func liveRelayCloseRequiresConfirmation() async throws {
        let relayProcess = WorkspaceTestTerminalProcess()
        let store = makeStore(
            relayProcess: relayProcess,
            closeDispositionResolver: { session in
                session.kind == .relaySSH ? .confirmSSHSession : .closeImmediately
            }
        )
        store.startIfNeeded()
        let localID = try #require(store.tabs.first?.id)
        store.createSSHTerminal()
        try await waitUntil { store.selectedSession?.lifecycle == .running }
        let relayID = try #require(store.selectedTab?.id)

        store.requestClose(relayID)
        try await waitUntil {
            if case .close = store.activeAlert { return true }
            return false
        }
        guard case let .close(prompt) = store.activeAlert else {
            Issue.record("Expected SSH close confirmation")
            return
        }
        #expect(prompt.tabID == relayID)
        #expect(prompt.disposition == .confirmSSHSession)

        store.dismissWorkspaceAlert()
        #expect(store.tabs.contains(where: { $0.id == relayID }))
        store.requestClose(relayID)
        try await waitUntil {
            if case .close = store.activeAlert { return true }
            return false
        }
        guard case let .close(secondPrompt) = store.activeAlert else {
            Issue.record("Expected second SSH close confirmation")
            return
        }
        store.confirmClose(secondPrompt)
        try await waitUntil { store.sessions[relayID] == nil }
        #expect(store.tabs.contains(where: { $0.id == localID && $0.kind == .local }))
        #expect(store.sessions[localID]?.kind == .local)
        store.cleanupAllSessions()
        try await waitUntil { store.sessions.isEmpty }
    }

    @Test("[TAB-003, TERM-STATE-001] an exited relay tab closes immediately")
    func exitedRelayClosesWithoutConfirmation() async throws {
        let relayProcess = WorkspaceTestTerminalProcess()
        let store = makeStore(
            relayProcess: relayProcess,
            closeDispositionResolver: { _ in .confirmSSHSession }
        )
        store.startIfNeeded()
        store.createSSHTerminal()
        try await waitUntil { store.selectedSession?.lifecycle == .running }
        let relayID = try #require(store.selectedTab?.id)

        await relayProcess.finish(status: .exited(code: 255))
        try await waitUntil {
            store.tabs.first(where: { $0.id == relayID })?.lifecycle == .exited(.exited(code: 255))
        }
        store.requestClose(relayID)

        try await waitUntil { store.sessions[relayID] == nil }
        #expect(store.activeAlert == nil)
        store.cleanupAllSessions()
        try await waitUntil { store.sessions.isEmpty }
    }

    @Test("[TAB-003, TERM-STATE-001] a failed relay tab closes immediately")
    func failedRelayClosesWithoutConfirmation() async throws {
        let store = TerminalWorkspaceStore(
            closeDispositionResolver: { _ in .confirmSSHSession },
            sessionFactory: { id, kind in
                if kind == .relaySSH {
                    return TerminalSession(
                        id: id,
                        kind: kind,
                        inheritedEnvironment: [:],
                        userHomeDirectory: "/fixture/home",
                        processLauncher: { _ in throw WorkspaceTestProcessError.launchFailed }
                    )
                }
                return TerminalSession(id: id, kind: kind)
            }
        )
        store.startIfNeeded()
        store.createSSHTerminal()
        try await waitUntil {
            if case .failed = store.selectedTab?.lifecycle { return true }
            return false
        }
        let relayID = try #require(store.selectedTab?.id)

        store.requestClose(relayID)

        try await waitUntil { store.sessions[relayID] == nil }
        #expect(store.activeAlert == nil)
        store.cleanupAllSessions()
        try await waitUntil { store.sessions.isEmpty }
    }

    @Test("[MAC-002, TAB-003] aggregate shutdown counts SSH sessions independently")
    func aggregateShutdownIncludesSSHSessionCount() async throws {
        let relayProcess = WorkspaceTestTerminalProcess()
        let store = makeStore(
            relayProcess: relayProcess,
            closeDispositionResolver: { session in
                session.kind == .relaySSH ? .confirmSSHSession : .confirmForegroundJob
            }
        )
        store.startIfNeeded()
        store.createSSHTerminal()
        try await waitUntil { store.tabs.count == 2 && store.tabs.allSatisfy(\.lifecycle.acceptsInput) }
        var decision: Bool?

        store.requestWorkspaceShutdown(.window) { decision = $0 }
        try await waitUntil {
            if case .shutdown = store.activeAlert { return true }
            return false
        }
        guard case let .shutdown(prompt) = store.activeAlert else {
            Issue.record("Expected mixed local/SSH shutdown prompt")
            return
        }
        #expect(prompt.foregroundJobCount == 1)
        #expect(prompt.sshSessionCount == 1)
        #expect(prompt.confirmationTerminalCount == 2)

        store.dismissWorkspaceAlert()
        #expect(decision == false)
        store.cleanupAllSessions()
        try await waitUntil { store.sessions.isEmpty }
    }

    @Test("[MAC-002, TAB-003] a live SSH session alone requires aggregate confirmation")
    func aggregateShutdownPromptsForLiveSSHWhenLocalIsIdle() async throws {
        let relayProcess = WorkspaceTestTerminalProcess()
        let store = makeStore(
            relayProcess: relayProcess,
            closeDispositionResolver: { session in
                session.kind == .relaySSH ? .confirmSSHSession : .closeImmediately
            }
        )
        store.startIfNeeded()
        store.createSSHTerminal()
        try await waitUntil {
            store.tabs.count == 2 && store.tabs.allSatisfy(\.lifecycle.acceptsInput)
        }
        var decision: Bool?

        store.requestWorkspaceShutdown(.window) { decision = $0 }
        try await waitUntil {
            if case .shutdown = store.activeAlert { return true }
            return false
        }
        guard case let .shutdown(prompt) = store.activeAlert else {
            Issue.record("Expected an SSH-only aggregate shutdown prompt")
            return
        }
        #expect(prompt.foregroundJobCount == 0)
        #expect(prompt.unknownForegroundActivityCount == 0)
        #expect(prompt.sshSessionCount == 1)
        #expect(prompt.confirmationTerminalCount == 1)
        #expect(decision == nil)

        store.dismissWorkspaceAlert()
        #expect(decision == false)
        #expect(store.tabs.count == 2)
        store.cleanupAllSessions()
        try await waitUntil { store.sessions.isEmpty }
    }

    private func makeStore(
        relayProcess: WorkspaceTestTerminalProcess,
        closeDispositionResolver: @escaping TerminalCloseDispositionResolver = {
            await $0.closeDisposition()
        }
    ) -> TerminalWorkspaceStore {
        TerminalWorkspaceStore(
            closeDispositionResolver: closeDispositionResolver,
            sessionFactory: { id, kind in
                if kind == .relaySSH {
                    return TerminalSession(
                        id: id,
                        kind: kind,
                        inheritedEnvironment: ["SSH_AUTH_SOCK": "/fixture/agent.sock"],
                        userHomeDirectory: "/fixture/home",
                        processLauncher: { _ in relayProcess }
                    )
                }
                return TerminalSession(id: id, kind: kind)
            }
        )
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for SSH workspace state")
    }
}
