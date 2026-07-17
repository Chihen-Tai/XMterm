import Foundation
import Testing
import XMtermCore
import XMtermTerminal
@testable import XMtermApp

@Suite("Workspace shutdown coordination", .serialized)
@MainActor
struct TerminalWorkspaceStoreTests {
    @Test("Overlapping window and application shutdown requests both resolve", .timeLimit(.minutes(1)))
    func overlappingShutdownRequestsResolveExactlyOnce() async throws {
        let store = TerminalWorkspaceStore(
            closeDispositionResolver: { _ in .confirmForegroundJob }
        )
        store.startIfNeeded()
        try await waitUntil { store.tabs.first?.lifecycle.acceptsInput == true }

        var decisions: [String] = []
        store.requestWorkspaceShutdown(.window) { approved in
            decisions.append("window:\(approved)")
        }
        try await waitUntil {
            if case .shutdown = store.activeAlert { return true }
            return false
        }
        guard case let .shutdown(prompt) = store.activeAlert else {
            Issue.record("Expected aggregate window-close prompt")
            store.cleanupAllSessions()
            return
        }

        store.confirmWorkspaceShutdown(prompt)
        store.requestWorkspaceShutdown(.application) { approved in
            decisions.append("application:\(approved)")
        }

        try await waitUntil { decisions.count == 2 }
        #expect(decisions == ["window:true", "application:true"])
        #expect(store.sessions.isEmpty)
        #expect(store.tabs.isEmpty)
    }

    @Test("Cancelling aggregate shutdown keeps the session alive and resolves every waiter")
    func aggregateShutdownCancellationResolvesEveryWaiter() async throws {
        let store = TerminalWorkspaceStore(
            closeDispositionResolver: { _ in .confirmForegroundJob }
        )
        store.startIfNeeded()
        try await waitUntil { store.tabs.first?.lifecycle.acceptsInput == true }

        var decisions: [Bool] = []
        store.requestWorkspaceShutdown(.window) { decisions.append($0) }
        store.requestWorkspaceShutdown(.application) { decisions.append($0) }
        try await waitUntil {
            if case .shutdown = store.activeAlert { return true }
            return false
        }
        guard case let .shutdown(prompt) = store.activeAlert else {
            Issue.record("Expected coalesced shutdown prompt")
            store.cleanupAllSessions()
            return
        }
        #expect(prompt.scope == .application)
        #expect(prompt.confirmationTerminalCount == 1)

        store.dismissWorkspaceAlert()

        #expect(decisions == [false, false])
        #expect(store.tabs.first?.lifecycle.acceptsInput == true)
        store.cleanupAllSessions()
        try await waitUntil { store.sessions.isEmpty }
    }

    @Test("[TAB-003] an idle shell closes without confirmation", .timeLimit(.minutes(1)))
    func idleShellClosesWithoutConfirmation() async throws {
        let store = TerminalWorkspaceStore()
        store.startIfNeeded()
        try await waitUntil { store.tabs.first?.lifecycle.acceptsInput == true }
        let id = try #require(store.tabs.first?.id)

        store.requestClose(id)

        try await waitUntil { !store.tabs.contains(where: { $0.id == id }) }
        #expect(store.activeAlert == nil)
        try await waitUntil { store.sessions[id] == nil }
    }

    @Test("[TAB-003] the default workspace prompts for a foreground job then returns to idle")
    func defaultWorkspaceTracksForegroundJobCompletion() async throws {
        let store = TerminalWorkspaceStore()
        store.startIfNeeded()
        try await waitUntil { store.tabs.first?.lifecycle.acceptsInput == true }
        let tab = try #require(store.tabs.first)
        let session = try #require(store.sessions[tab.id])

        session.terminalView.send(Array("/bin/sleep 30\n".utf8))
        try await waitUntilAsync {
            await session.closeDisposition() == .confirmForegroundJob
        }
        store.requestClose(tab.id)
        try await waitUntil {
            if case .close = store.activeAlert { return true }
            return false
        }
        store.dismissWorkspaceAlert()

        session.terminalView.send([0x03])
        try await waitUntilAsync {
            await session.closeDisposition() == .closeImmediately
        }

        session.terminalView.send(Array("/bin/sleep 1\n".utf8))
        try await waitUntilAsync {
            await session.closeDisposition() == .confirmForegroundJob
        }
        try await waitUntilAsync {
            await session.closeDisposition() == .closeImmediately
        }

        store.requestClose(tab.id)
        try await waitUntil { !store.tabs.contains(where: { $0.id == tab.id }) }
        #expect(store.activeAlert == nil)
        try await waitUntil { store.sessions[tab.id] == nil }
    }

    @Test("[TAB-003] a foreground process requires confirmation", .timeLimit(.minutes(1)))
    func foregroundProcessRequiresConfirmation() async throws {
        let store = TerminalWorkspaceStore(
            closeDispositionResolver: { _ in .confirmForegroundJob }
        )
        store.startIfNeeded()
        try await waitUntil { store.tabs.first?.lifecycle.acceptsInput == true }
        let id = try #require(store.tabs.first?.id)

        store.requestClose(id)
        try await waitUntil {
            if case .close = store.activeAlert { return true }
            return false
        }

        guard case let .close(prompt) = store.activeAlert else {
            Issue.record("Expected a close confirmation for the foreground job")
            store.cleanupAllSessions()
            return
        }
        #expect(store.tabs.contains(where: { $0.id == id }))
        store.confirmClose(prompt)
        try await waitUntil { store.sessions[id] == nil }
    }

    @Test("[TAB-003] a live foreground-query failure uses the documented conservative prompt")
    func queryFailureRequiresConservativeConfirmation() async throws {
        let store = TerminalWorkspaceStore(
            closeDispositionResolver: { _ in .confirmUnknownForegroundActivity }
        )
        store.startIfNeeded()
        try await waitUntil { store.tabs.first?.lifecycle.acceptsInput == true }
        let id = try #require(store.tabs.first?.id)

        store.requestClose(id)
        try await waitUntil {
            if case .close = store.activeAlert { return true }
            return false
        }

        #expect(store.tabs.contains(where: { $0.id == id }))
        store.dismissWorkspaceAlert()
        store.cleanupAllSessions()
        try await waitUntil { store.sessions.isEmpty }
    }

    @Test("[TAB-003, TERM-STATE-001] an exited terminal closes immediately", .timeLimit(.minutes(1)))
    func exitedTerminalClosesImmediately() async throws {
        let store = TerminalWorkspaceStore()
        store.startIfNeeded()
        try await waitUntil { store.tabs.first?.lifecycle.acceptsInput == true }
        let tab = try #require(store.tabs.first)
        let session = try #require(store.sessions[tab.id])

        session.terminalView.send(Array("exit\n".utf8))
        try await waitUntil {
            if case .exited = store.tabs.first(where: { $0.id == tab.id })?.lifecycle {
                return true
            }
            return false
        }

        store.requestClose(tab.id)
        try await waitUntil { !store.tabs.contains(where: { $0.id == tab.id }) }
        #expect(store.activeAlert == nil)
        try await waitUntil { store.sessions[tab.id] == nil }
    }

    @Test("[TAB-003, TERM-STATE-001] a failed terminal closes immediately")
    func failedTerminalClosesImmediately() async throws {
        let store = TerminalWorkspaceStore(
            sessionFactory: { id, _ in
                TerminalSession(
                    id: id,
                    shellResolver: { throw TerminalShellResolutionError.shellUnavailable }
                )
            }
        )
        store.startIfNeeded()
        try await waitUntil {
            if case .failed = store.tabs.first?.lifecycle { return true }
            return false
        }
        let id = try #require(store.tabs.first?.id)

        store.requestClose(id)

        try await waitUntil { !store.tabs.contains(where: { $0.id == id }) }
        #expect(store.activeAlert == nil)
        try await waitUntil { store.sessions[id] == nil }
    }

    @Test("[TAB-003] close decisions remain independent across tabs", .timeLimit(.minutes(1)))
    func closeDecisionsRemainIndependentAcrossTabs() async throws {
        let fixture = CloseDispositionFixture()
        let store = TerminalWorkspaceStore(
            closeDispositionResolver: { session in
                fixture.disposition(for: session.id)
            }
        )
        store.startIfNeeded()
        store.createTerminal()
        try await waitUntil {
            store.tabs.count == 2 && store.tabs.allSatisfy(\.lifecycle.acceptsInput)
        }
        let first = store.tabs[0].id
        let second = store.tabs[1].id
        let firstSessionID = try #require(store.sessions[first]?.id)
        let secondSessionID = try #require(store.sessions[second]?.id)
        fixture.replaceDispositions(with: [
            firstSessionID: .confirmForegroundJob,
            secondSessionID: .closeImmediately
        ])

        store.requestClose(second)
        try await waitUntil { !store.tabs.contains(where: { $0.id == second }) }
        #expect(store.activeAlert == nil)
        #expect(store.tabs.contains(where: { $0.id == first }))

        store.requestClose(first)
        try await waitUntil {
            if case .close = store.activeAlert { return true }
            return false
        }
        guard case let .close(prompt) = store.activeAlert else {
            Issue.record("Expected only the first tab to require confirmation")
            store.cleanupAllSessions()
            return
        }
        #expect(prompt.tabID == first)

        store.confirmClose(prompt)
        try await waitUntil { store.sessions.isEmpty }
    }

    @Test("[MAC-002] an all-idle workspace shuts down without an aggregate prompt")
    func idleWorkspaceShutsDownWithoutPrompt() async throws {
        let store = TerminalWorkspaceStore(
            closeDispositionResolver: { _ in .closeImmediately }
        )
        store.startIfNeeded()
        try await waitUntil { store.tabs.first?.lifecycle.acceptsInput == true }
        var decision: Bool?

        store.requestWorkspaceShutdown(.window) { decision = $0 }

        try await waitUntil { decision != nil }
        #expect(decision == true)
        #expect(store.activeAlert == nil)
        #expect(store.tabs.isEmpty)
        #expect(store.sessions.isEmpty)
    }

    @Test("[MAC-002] aggregate shutdown counts only mixed foreground and unknown states")
    func aggregateShutdownClassifiesTabsIndependently() async throws {
        let fixture = CloseDispositionFixture()
        let store = TerminalWorkspaceStore(
            closeDispositionResolver: { session in
                fixture.disposition(for: session.id)
            }
        )
        store.startIfNeeded()
        store.createTerminal()
        store.createTerminal()
        try await waitUntil {
            store.tabs.count == 3 && store.tabs.allSatisfy(\.lifecycle.acceptsInput)
        }
        let firstSessionID = try #require(store.sessions[store.tabs[0].id]?.id)
        let secondSessionID = try #require(store.sessions[store.tabs[1].id]?.id)
        let thirdSessionID = try #require(store.sessions[store.tabs[2].id]?.id)
        fixture.replaceDispositions(with: [
            firstSessionID: .closeImmediately,
            secondSessionID: .confirmForegroundJob,
            thirdSessionID: .confirmUnknownForegroundActivity
        ])
        var decision: Bool?

        store.requestWorkspaceShutdown(.window) { decision = $0 }
        try await waitUntil {
            if case .shutdown = store.activeAlert { return true }
            return false
        }

        guard case let .shutdown(prompt) = store.activeAlert else {
            Issue.record("Expected one aggregate shutdown prompt")
            store.cleanupAllSessions()
            return
        }
        #expect(prompt.foregroundJobCount == 1)
        #expect(prompt.unknownForegroundActivityCount == 1)
        #expect(prompt.confirmationTerminalCount == 2)
        #expect(decision == nil)

        store.dismissWorkspaceAlert()
        #expect(decision == false)
        #expect(store.tabs.count == 3)
        store.cleanupAllSessions()
        try await waitUntil { store.sessions.isEmpty }
    }

    @Test("[MAC-002] terminal creation is blocked while a shutdown decision is pending")
    func shutdownPromptPreventsSessionSetDrift() async throws {
        let store = TerminalWorkspaceStore(
            closeDispositionResolver: { _ in .confirmForegroundJob }
        )
        store.startIfNeeded()
        try await waitUntil { store.tabs.first?.lifecycle.acceptsInput == true }
        var decision: Bool?
        store.requestWorkspaceShutdown(.window) { decision = $0 }
        try await waitUntil {
            if case .shutdown = store.activeAlert { return true }
            return false
        }

        #expect(!store.canCreateTerminal)
        store.createTerminal()
        #expect(store.tabs.count == 1)

        store.dismissWorkspaceAlert()
        #expect(decision == false)
        #expect(store.canCreateTerminal)
        store.createTerminal()
        try await waitUntil { store.tabs.count == 2 }
        store.cleanupAllSessions()
        try await waitUntil { store.sessions.isEmpty }
    }

    @Test("[TAB-003] a stale asynchronous close decision cannot target a removed tab")
    func staleCloseDecisionIsDiscarded() async throws {
        let fixture = SuspendedCloseDispositionFixture()
        let store = TerminalWorkspaceStore(
            closeDispositionResolver: { _ in await fixture.resolve() }
        )
        store.startIfNeeded()
        try await waitUntil { store.tabs.first?.lifecycle.acceptsInput == true }
        let id = try #require(store.tabs.first?.id)

        store.requestClose(id)
        try await waitUntil { fixture.hasPendingResolution }
        store.cleanupAllSessions()
        try await waitUntil { store.sessions.isEmpty }

        fixture.complete(with: .confirmForegroundJob)
        await Task.yield()

        #expect(store.tabs.isEmpty)
        #expect(store.activeAlert == nil)
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for workspace state")
    }

    private func waitUntilAsync(
        _ condition: @escaping @MainActor () async -> Bool
    ) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for asynchronous workspace state")
    }
}

@MainActor
private final class CloseDispositionFixture {
    private var dispositions: [UUID: TerminalCloseDisposition] = [:]

    func disposition(for id: UUID) -> TerminalCloseDisposition {
        dispositions[id] ?? .closeImmediately
    }

    func replaceDispositions(with replacement: [UUID: TerminalCloseDisposition]) {
        dispositions = replacement
    }
}

@MainActor
private final class SuspendedCloseDispositionFixture {
    private var continuation: CheckedContinuation<TerminalCloseDisposition, Never>?

    var hasPendingResolution: Bool { continuation != nil }

    func resolve() async -> TerminalCloseDisposition {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func complete(with disposition: TerminalCloseDisposition) {
        let pendingContinuation = continuation
        continuation = nil
        pendingContinuation?.resume(returning: disposition)
    }
}
