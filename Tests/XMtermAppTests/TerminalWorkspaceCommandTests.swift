import Foundation
import Testing
import XMtermCore
import XMtermRemote
import XMtermTerminal
@testable import XMtermApp

@Suite("Terminal workspace commands")
@MainActor
struct TerminalWorkspaceCommandTests {
    @Test("[MAC-001, TAB-001] scene command fallback directly reaches the active workspace")
    func fallbackActionsCreateLocalAndRelayTabs() async throws {
        let store = TerminalWorkspaceStore(
            sessionFactory: { id, kind in
                let process = WorkspaceTestTerminalProcess()
                return TerminalSession(
                    id: id,
                    kind: kind,
                    inheritedEnvironment: [:],
                    userHomeDirectory: "/fixture/home",
                    processLauncher: { _ in process }
                )
            }
        )
        let router = TerminalCommandRouter()
        router.attach(workspace: store, closeWindow: {})

        #expect(router.canCreateTerminal)
        #expect(!router.canCloseTerminal)
        #expect(!router.canFindInTerminal)
        router.newTerminal()
        router.newSSHTerminal()

        try await waitUntil { store.tabs.count == 2 }
        #expect(store.tabs.map(\.kind) == [.local, .relaySSH])
        #expect(router.canCloseTerminal)
        #expect(router.canFindInTerminal)
        let blockingAlert = TerminalWorkspaceAlert.error(
            id: UUID(),
            message: "fixture"
        )
        store.activeAlert = blockingAlert
        #expect(!router.canCloseTerminal)

        router.closeTerminal()
        try await Task.sleep(for: .milliseconds(20))

        #expect(store.activeAlert == blockingAlert)
        #expect(store.tabs.count == 2)
        store.activeAlert = nil
        store.cleanupAllSessions()
        try await waitUntil { store.sessions.isEmpty }
    }

    @Test("[MAC-001, MAC-003] command routing rebinds to a recreated window workspace")
    func routerRebindsWithoutRetainingClosedWorkspace() async throws {
        let firstStore = makeStore()
        let secondStore = makeStore()
        let router = TerminalCommandRouter()
        router.attach(workspace: firstStore, closeWindow: {})
        router.newTerminal()
        try await waitUntil { firstStore.tabs.count == 1 }

        router.detach(from: firstStore)
        #expect(!router.canCreateTerminal)
        #expect(!router.canCloseTerminal)
        router.attach(workspace: secondStore, closeWindow: {})
        router.newSSHTerminal()

        try await waitUntil { secondStore.tabs.count == 1 }
        #expect(firstStore.tabs.count == 1)
        #expect(secondStore.tabs.map(\.kind) == [.relaySSH])
        firstStore.cleanupAllSessions()
        secondStore.cleanupAllSessions()
        try await waitUntil {
            firstStore.sessions.isEmpty && secondStore.sessions.isEmpty
        }
    }

    @Test("[SESS-009, MAC-001] injected session workflow owns command actions")
    func injectedWorkflowOwnsNewChooseAndManageCommands() {
        let store = makeStore()
        let router = TerminalCommandRouter()
        var newTerminalCount = 0
        var chooseSessionCount = 0
        var manageSessionCount = 0
        router.attach(
            workspace: store,
            closeWindow: {},
            newTerminal: { newTerminalCount += 1 },
            chooseSession: { chooseSessionCount += 1 },
            manageSessions: { manageSessionCount += 1 }
        )

        router.newTerminal()
        router.chooseSession()
        router.manageSessions()

        #expect(newTerminalCount == 1)
        #expect(chooseSessionCount == 1)
        #expect(manageSessionCount == 1)
        #expect(store.tabs.isEmpty)
    }

    @Test("[SESS-009, TERM-KEY-002] terminal-focused Command-T requests the saved-profile workflow")
    func terminalFocusedNewTabRequestsProfileWorkflow() async throws {
        let store = makeStore()
        var requestCount = 0
        store.newTerminalRequest = { requestCount += 1 }
        store.startIfNeeded()
        try await waitUntil { store.selectedSession != nil }
        let initialTabs = store.tabs.count

        store.selectedSession?.onLocalAction?(.newTab)

        #expect(requestCount == 1)
        #expect(store.tabs.count == initialTabs)
        store.cleanupAllSessions()
        try await waitUntil { store.sessions.isEmpty }
    }

    @Test("[SESS-011, MAC-001] remote commands route only to the exact selected runtime owner")
    func remoteCommandsRejectStaleTabOwnerAndRouteReplacement() throws {
        let firstOwner = RemoteWorkspaceFocusOwner(
            runtimeID: TerminalSessionID(),
            workspaceID: RemoteWorkspaceID()
        )
        let secondOwner = RemoteWorkspaceFocusOwner(
            runtimeID: TerminalSessionID(),
            workspaceID: RemoteWorkspaceID()
        )
        var currentOwner: RemoteWorkspaceFocusOwner? = firstOwner
        var performed: [(RemoteWorkspaceFocusOwner, RemoteWorkspaceAction)] = []

        let firstRoute = RemoteWorkspaceCommandRoute(
            actions: focusedActions(
                owner: firstOwner,
                currentOwner: { currentOwner },
                performed: { performed.append((firstOwner, $0)) }
            )
        )
        #expect(firstRoute.perform(.refresh))
        #expect(performed.map(\.0) == [firstOwner])

        currentOwner = secondOwner
        #expect(!firstRoute.perform(.refresh))

        let secondRoute = RemoteWorkspaceCommandRoute(
            actions: focusedActions(
                owner: secondOwner,
                currentOwner: { currentOwner },
                performed: { performed.append((secondOwner, $0)) }
            )
        )
        #expect(secondRoute.perform(.refresh))
        #expect(performed.map(\.0) == [firstOwner, secondOwner])
    }

    @Test("[FILE-WORKSPACE-001, MAC-001] local selection exposes no remote command actions")
    func localRuntimeDisablesRemoteCommandsWithoutChangingTerminalCommands() {
        let remoteRoute = RemoteWorkspaceCommandRoute(actions: nil)
        for action in RemoteWorkspaceAction.allCases {
            #expect(!remoteRoute.isEnabled(action))
            #expect(!remoteRoute.perform(action))
        }

        let store = makeStore()
        let terminalRouter = TerminalCommandRouter()
        var newTerminalCount = 0
        terminalRouter.attach(
            workspace: store,
            closeWindow: {},
            newTerminal: { newTerminalCount += 1 }
        )

        #expect(terminalRouter.canCreateTerminal)
        terminalRouter.newTerminal()
        #expect(newTerminalCount == 1)
    }

    @Test("[FILE-NAV-002, MAC-001] navigation shortcuts map to directory-only actions")
    func remoteNavigationShortcutContract() throws {
        #expect(RemoteWorkspaceKeyboardCommand.openSelection.key == .downArrow)
        #expect(RemoteWorkspaceKeyboardCommand.openSelection.modifiers == .command)
        #expect(RemoteWorkspaceKeyboardCommand.openSelection.action == .openSelection)
        #expect(RemoteWorkspaceKeyboardCommand.goToParent.key == .upArrow)
        #expect(RemoteWorkspaceKeyboardCommand.goToParent.modifiers == .command)
        #expect(RemoteWorkspaceKeyboardCommand.goToParent.action == .goToParent)

        let owner = RemoteWorkspaceFocusOwner(
            runtimeID: TerminalSessionID(),
            workspaceID: RemoteWorkspaceID()
        )
        var performed: [RemoteWorkspaceAction] = []
        let filePolicy = RemoteWorkspaceActionPolicy(
            availability: .available,
            currentDirectory: try path("/work"),
            canGoBack: false,
            canGoForward: false,
            selectedEntry: try entry("/work/readme.txt", kind: .regular)
        )
        let route = RemoteWorkspaceCommandRoute(
            actions: RemoteWorkspaceFocusedActions(
                owner: owner,
                policy: filePolicy,
                currentOwner: { owner },
                perform: { performed.append($0) }
            )
        )

        #expect(!route.perform(RemoteWorkspaceKeyboardCommand.openSelection.action))
        #expect(route.perform(RemoteWorkspaceKeyboardCommand.goToParent.action))
        #expect(performed == [.goToParent])
    }

    @Test("[FILE-COPY-001, MAC-001] command and context copy actions share policy")
    func remoteCopyAndContextActionsUseSharedPolicy() throws {
        let owner = RemoteWorkspaceFocusOwner(
            runtimeID: TerminalSessionID(),
            workspaceID: RemoteWorkspaceID()
        )
        var performed: [RemoteWorkspaceAction] = []
        let route = RemoteWorkspaceCommandRoute(
            actions: focusedActions(
                owner: owner,
                currentOwner: { owner },
                performed: { performed.append($0) }
            )
        )

        #expect(RemoteWorkspaceCommandRoute.contextCopyActions == RemoteWorkspaceAction.copyActions)
        for action in RemoteWorkspaceCommandRoute.contextCopyActions {
            #expect(route.isEnabled(action))
            #expect(route.perform(action))
        }
        #expect(!route.isEnabled(.renameSelection))
        #expect(!route.perform(.renameSelection))
        #expect(performed == RemoteWorkspaceAction.copyActions)
    }

    private func makeStore() -> TerminalWorkspaceStore {
        TerminalWorkspaceStore(
            sessionFactory: { id, kind in
                let process = WorkspaceTestTerminalProcess()
                return TerminalSession(
                    id: id,
                    kind: kind,
                    inheritedEnvironment: [:],
                    userHomeDirectory: "/fixture/home",
                    processLauncher: { _ in process }
                )
            }
        )
    }

    private func focusedActions(
        owner: RemoteWorkspaceFocusOwner,
        currentOwner: @escaping @MainActor () -> RemoteWorkspaceFocusOwner?,
        performed: @escaping @MainActor (RemoteWorkspaceAction) -> Void
    ) throws -> RemoteWorkspaceFocusedActions {
        RemoteWorkspaceFocusedActions(
            owner: owner,
            policy: RemoteWorkspaceActionPolicy(
                availability: .available,
                currentDirectory: try path("/work"),
                canGoBack: true,
                canGoForward: true,
                selectedEntry: try entry("/work/reports", kind: .directory)
            ),
            currentOwner: currentOwner,
            perform: performed
        )
    }

    private func path(_ value: String) throws -> RemotePath {
        try RemotePath(rawBytes: Array(value.utf8))
    }

    private func entry(
        _ value: String,
        kind: RemoteFileEntry.Kind
    ) throws -> RemoteFileEntry {
        try RemoteFileEntry(path: path(value), kind: kind)
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for terminal workspace command result")
    }
}
