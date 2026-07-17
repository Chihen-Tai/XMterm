import Foundation
import Testing
@testable import XMtermCore

@Suite("SSH terminal target and lifecycle")
struct SSHTerminalTargetTests {
    @Test("[TAB-005, TERM-STATE-001] SSH process state is honest about process lifetime")
    func sshProcessStateNeverClaimsNetworkConnection() throws {
        #expect(try TerminalLifecycle.idle.transitioned(by: .startRequested) == .starting)
        #expect(SSHProcessState(lifecycle: .idle) == .idle)
        #expect(SSHProcessState(lifecycle: .starting) == .starting)
        #expect(SSHProcessState(lifecycle: .running) == .processRunning)
        #expect(SSHProcessState(lifecycle: .closing) == .closing)
        #expect(
            SSHProcessState(lifecycle: .exited(.exited(code: 255)))
                == .exited(.exited(code: 255))
        )
        #expect(
            SSHProcessState(lifecycle: .failed(.launch(message: "fixture")))
                == .failed(.launch(message: "fixture"))
        )
    }

    @Test("[TAB-001, TAB-002, TAB-005] Local and relay tabs coexist with stable kinds and titles")
    func localAndRelayTabsCoexistWithStableIdentity() throws {
        let localID = try #require(
            UUID(uuidString: "00000000-0000-0000-0000-000000000101")
        )
        let relayID = try #require(
            UUID(uuidString: "00000000-0000-0000-0000-000000000102")
        )
        let secondRelayID = try #require(
            UUID(uuidString: "00000000-0000-0000-0000-000000000103")
        )

        let state = try TerminalTabsState()
            .creatingTab(kind: .local, id: localID)
            .creatingTab(kind: .relaySSH, id: relayID)
            .creatingTab(kind: .relaySSH, id: secondRelayID)

        #expect(state.tabs.map(\.id) == [localID, relayID, secondRelayID])
        #expect(state.tabs.map(\.kind) == [.local, .relaySSH, .relaySSH])
        #expect(state.tabs.map(\.title) == ["Local Shell", "Relay Host", "Relay Host 2"])
        #expect(state.tabs.allSatisfy { $0.lifecycle == .idle })
        #expect(state.selectedTabID == secondRelayID)
    }

    @Test("[TAB-003] Closing a relay tab preserves local tab identity and selection")
    func closingRelayTabDoesNotAffectLocalTab() throws {
        let localID = try #require(
            UUID(uuidString: "00000000-0000-0000-0000-000000000111")
        )
        let relayID = try #require(
            UUID(uuidString: "00000000-0000-0000-0000-000000000112")
        )
        let state = try TerminalTabsState()
            .creatingTab(kind: .local, id: localID)
            .creatingTab(kind: .relaySSH, id: relayID)
            .selectingTab(id: localID)

        let closed = state.closingTab(id: relayID)

        #expect(closed.tabs.map(\.id) == [localID])
        #expect(closed.tabs.first?.kind == .local)
        #expect(closed.selectedTabID == localID)
    }
}
