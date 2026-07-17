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
            actions: try focusedActions(
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
            actions: try focusedActions(
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
            actions: try focusedActions(
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

    @Test("[FILE-NAV-002, SESS-011] Back, Forward, Parent, Refresh, and open route to the exact workspace methods")
    func performerRoutesNavigationActionsToWorkspace() async throws {
        let fixture = try makeRemoteFixture()
        let workspace = RemoteWorkspace(provider: fixture.makeProvider())
        let writer = CommandTestPasteboardWriter()
        let performer = RemoteWorkspaceActionPerformer(
            workspace: workspace,
            pasteboard: RemotePathPasteboard(writer: writer)
        )
        workspace.start()
        try await waitUntil { workspace.availability == .available }
        #expect(workspace.currentDirectory == fixture.work)

        workspace.selectEntry(fixture.reports.path)
        performer.perform(.openSelection)
        try await waitUntil { workspace.currentDirectory == fixture.reports.path }
        #expect(workspace.backHistory.map(\.directory) == [fixture.work])

        performer.perform(.goBack)
        try await waitUntil { workspace.currentDirectory == fixture.work }
        #expect(workspace.forwardHistory.map(\.directory) == [fixture.reports.path])

        performer.perform(.goForward)
        try await waitUntil { workspace.currentDirectory == fixture.reports.path }
        #expect(workspace.forwardHistory.isEmpty)

        performer.perform(.goToParent)
        try await waitUntil { workspace.currentDirectory == fixture.work }
        #expect(workspace.forwardHistory.isEmpty)

        workspace.selectEntry(fixture.readme.path)
        let provider = fixture.recordedProviders.last
        let listCountBeforeRefresh = await provider?.recordedAttempts
            .count(where: { $0 == .listDirectory }) ?? 0
        let backHistoryBeforeRefresh = workspace.backHistory.map(\.directory)
        performer.perform(.refresh)
        try await waitUntilAsync {
            let listCount = await provider?.recordedAttempts
                .count(where: { $0 == .listDirectory }) ?? 0
            return listCount == listCountBeforeRefresh + 1 && workspace.pendingDirectory == nil
        }
        #expect(workspace.currentDirectory == fixture.work)
        #expect(workspace.backHistory.map(\.directory) == backHistoryBeforeRefresh)
        #expect(workspace.selectedEntry == fixture.readme.path)
        #expect(writer.writtenItems.isEmpty)
    }

    @Test("[FILE-STATE-001, SESS-011] workspace retry routes to RemoteWorkspace.retry")
    func performerRoutesRetryWorkspace() async throws {
        let fixture = try makeRemoteFixture()
        let timeout = RemoteFileError(category: .timeout)
        let provider = InMemoryRemoteFileProvider(
            initialDirectory: fixture.work,
            directoryGraph: [:],
            deterministicResponses: .init(initialDirectory: .failure(timeout))
        )
        let workspace = RemoteWorkspace(provider: provider)
        let performer = RemoteWorkspaceActionPerformer(
            workspace: workspace,
            pasteboard: RemotePathPasteboard(writer: CommandTestPasteboardWriter())
        )
        workspace.start()
        try await waitUntil { workspace.availability == .failed(timeout) }

        #expect(performer.currentPolicy().isEnabled(.retryWorkspace))
        performer.perform(.retryWorkspace)

        try await waitUntilAsync {
            let resolveCount = await provider.recordedAttempts
                .count(where: { $0 == .resolveInitialDirectory })
            return resolveCount == 2 && workspace.availability == .failed(timeout)
        }
    }

    @Test("[FILE-STATE-001, FILE-NAV-002] directory retry routes to the exact expanded child")
    func performerRoutesRetryDirectoryToExpandedChild() async throws {
        let fixture = try makeRemoteFixture()
        let provider = fixture.makeProvider()
        let workspace = RemoteWorkspace(provider: provider)
        let performer = RemoteWorkspaceActionPerformer(
            workspace: workspace,
            pasteboard: RemotePathPasteboard(writer: CommandTestPasteboardWriter())
        )
        workspace.start()
        try await waitUntil { workspace.availability == .available }

        workspace.setExpanded(fixture.broken.path, isExpanded: true)
        try await waitUntil {
            if case .failed = workspace.directoryStates[fixture.broken.path] { return true }
            return false
        }
        workspace.selectEntry(fixture.broken.path)
        #expect(performer.currentPolicy().isEnabled(.retryDirectory))

        let listCountBeforeRetry = await provider.recordedAttempts
            .count(where: { $0 == .listDirectory })
        performer.perform(.retryDirectory)

        try await waitUntilAsync {
            let listCount = await provider.recordedAttempts
                .count(where: { $0 == .listDirectory })
            return listCount == listCountBeforeRetry + 1
        }
        try await waitUntil {
            if case .failed = workspace.directoryStates[fixture.broken.path] { return true }
            return false
        }
        #expect(workspace.expandedDirectories.contains(fixture.broken.path))
    }

    @Test("[FILE-COPY-001] copy actions route exact text through the pasteboard adapter")
    func performerRoutesCopyActionsThroughPasteboard() async throws {
        let fixture = try makeRemoteFixture()
        let workspace = RemoteWorkspace(provider: fixture.makeProvider())
        let writer = CommandTestPasteboardWriter()
        let performer = RemoteWorkspaceActionPerformer(
            workspace: workspace,
            pasteboard: RemotePathPasteboard(writer: writer)
        )
        workspace.start()
        try await waitUntil { workspace.availability == .available }

        workspace.selectEntry(fixture.reports.path)
        performer.perform(.copyPath)
        performer.perform(.copyName)
        performer.perform(.copyParentDirectory)
        performer.perform(.copyShellQuotedPath)
        #expect(writer.writtenItems == ["/work/reports", "reports", "/work", "'/work/reports'"])

        workspace.selectEntry(nil)
        performer.perform(.copyPath)
        #expect(writer.writtenItems.last == "/work")
        #expect(writer.writtenItems.allSatisfy { !$0.hasSuffix("\n") && !$0.hasSuffix("\r") })
    }

    @Test("[FILE-COPY-001, MAC-001] context copy targets the clicked entry through the same policy")
    func contextCopyTargetsClickedEntryWithSharedPolicy() async throws {
        let fixture = try makeRemoteFixture()
        let workspace = RemoteWorkspace(provider: fixture.makeProvider())
        let writer = CommandTestPasteboardWriter()
        let performer = RemoteWorkspaceActionPerformer(
            workspace: workspace,
            pasteboard: RemotePathPasteboard(writer: writer)
        )
        workspace.start()
        try await waitUntil { workspace.availability == .available }
        workspace.selectEntry(fixture.readme.path)

        #expect(performer.contextPolicy(for: fixture.reports).isEnabled(.copyPath))
        #expect(performer.performContextCopy(.copyPath, target: fixture.reports.path))
        #expect(writer.writtenItems == ["/work/reports"])
        #expect(workspace.selectedEntry == fixture.readme.path)

        let lossyEntry = try RemoteFileEntry(
            path: RemotePath(rawBytes: [0x2F, 0x80]),
            kind: .regular
        )
        #expect(!performer.contextPolicy(for: lossyEntry).isEnabled(.copyPath))
        #expect(!performer.performContextCopy(.copyPath, target: lossyEntry.path))
        #expect(writer.writtenItems == ["/work/reports"])
    }

    @Test("[SESS-011, FILE-WORKSPACE-001] the selected focus owner follows tab selection exactly")
    func storeSelectedOwnerFollowsTabSelection() async throws {
        let fixture = try makeRemoteFixture()
        let store = makeRuntimeStore(fixture: fixture)

        store.createSSHTerminal()
        try await waitUntil { store.tabs.count == 1 && store.selectedRuntime != nil }
        let firstTabID = try #require(store.selectedTab?.id)
        let firstRuntimeID = try #require(store.selectedRuntime?.id)
        let firstOwner = try #require(store.selectedRemoteWorkspaceFocusOwner)
        #expect(firstOwner.runtimeID == firstRuntimeID)
        #expect(firstOwner.workspaceID == fixture.recordedWorkspaces.first?.id)

        store.createSSHTerminal()
        try await waitUntil { store.tabs.count == 2 && fixture.recordedWorkspaces.count == 2 }
        let secondOwner = try #require(store.selectedRemoteWorkspaceFocusOwner)
        #expect(secondOwner.workspaceID == fixture.recordedWorkspaces.last?.id)
        #expect(secondOwner != firstOwner)
        #expect(secondOwner.runtimeID != firstOwner.runtimeID)
        #expect(fixture.recordedWorkspaces.first !== fixture.recordedWorkspaces.last)
        let sourceProfileIDs = Set(
            store.runtimes.values.map(\.launchSpecification.sourceProfileID)
        )
        #expect(sourceProfileIDs.count == 1)

        store.createTerminal()
        try await waitUntil { store.tabs.count == 3 && store.selectedTab?.kind == .local }
        #expect(store.selectedRemoteWorkspaceFocusOwner == nil)

        store.selectTab(firstTabID)
        #expect(store.selectedRemoteWorkspaceFocusOwner == firstOwner)
        store.cleanupAllSessions()
        try await waitUntil { store.sessions.isEmpty }
    }

    @Test("[SESS-011, MAC-001] stale focused actions cannot reach a workspace after tab switching")
    func staleFocusedActionsCannotActAfterTabSwitch() async throws {
        let fixture = try makeRemoteFixture()
        let store = makeRuntimeStore(fixture: fixture)
        store.createSSHTerminal()
        try await waitUntil { store.tabs.count == 1 && store.selectedRuntime != nil }
        let firstRuntimeID = try #require(store.selectedRuntime?.id)
        let firstWorkspace = try #require(fixture.recordedWorkspaces.first)
        try await waitUntil { firstWorkspace.availability == .available }

        let actions = RemoteWorkspaceFocusedActions.forRuntime(
            runtimeID: firstRuntimeID,
            workspace: firstWorkspace,
            pasteboard: RemotePathPasteboard(writer: CommandTestPasteboardWriter()),
            currentOwner: { [weak store] in store?.selectedRemoteWorkspaceFocusOwner }
        )
        let route = RemoteWorkspaceCommandRoute(actions: actions)
        #expect(route.isEnabled(.refresh))
        #expect(route.perform(.refresh))
        try await waitUntil { workspacePendingSettled(firstWorkspace) }

        store.createSSHTerminal()
        try await waitUntil { store.tabs.count == 2 && fixture.recordedWorkspaces.count == 2 }
        let firstProvider = try #require(fixture.recordedProviders.first)
        let listCountAfterSwitch = await firstProvider.recordedAttempts
            .count(where: { $0 == .listDirectory })
        #expect(!route.isEnabled(.refresh))
        #expect(!route.perform(.refresh))

        store.createTerminal()
        try await waitUntil { store.selectedTab?.kind == .local }
        #expect(!route.perform(.refresh))
        let finalListCount = await firstProvider.recordedAttempts
            .count(where: { $0 == .listDirectory })
        #expect(finalListCount == listCountAfterSwitch)
        store.cleanupAllSessions()
        try await waitUntil { store.sessions.isEmpty }
    }

    @Test("[FILE-SEL-001, FILE-NAV-002] sidebar interaction routes selection, disclosure, and breadcrumbs")
    func sidebarInteractionRoutesToWorkspace() async throws {
        let fixture = try makeRemoteFixture()
        let provider = fixture.makeProvider()
        let workspace = RemoteWorkspace(provider: provider)
        let interaction = RemoteWorkspaceSidebarInteraction(workspace: workspace)
        workspace.start()
        try await waitUntil { workspace.availability == .available }

        interaction.select(fixture.readme.path)
        #expect(workspace.selectedEntry == fixture.readme.path)
        interaction.select(nil)
        #expect(workspace.selectedEntry == nil)

        interaction.setExpanded(fixture.reports.path, isExpanded: true)
        #expect(workspace.expandedDirectories.contains(fixture.reports.path))
        try await waitUntil {
            if case .loaded = workspace.directoryStates[fixture.reports.path] { return true }
            return false
        }
        interaction.setExpanded(fixture.reports.path, isExpanded: false)
        #expect(!workspace.expandedDirectories.contains(fixture.reports.path))

        interaction.openEntry(fixture.readme.path)
        try await waitUntil { workspacePendingSettled(workspace) }
        #expect(workspace.currentDirectory == fixture.work)

        interaction.openEntry(fixture.reports.path)
        try await waitUntil { workspace.currentDirectory == fixture.reports.path }

        interaction.openBreadcrumb(fixture.work)
        try await waitUntil { workspace.currentDirectory == fixture.work }

        workspace.setExpanded(fixture.broken.path, isExpanded: true)
        try await waitUntil {
            if case .failed = workspace.directoryStates[fixture.broken.path] { return true }
            return false
        }
        let listCountBeforeRetry = await provider.recordedAttempts
            .count(where: { $0 == .listDirectory })
        interaction.retryDirectory(fixture.broken.path)
        try await waitUntilAsync {
            let listCount = await provider.recordedAttempts
                .count(where: { $0 == .listDirectory })
            return listCount == listCountBeforeRetry + 1
        }
    }

    @Test("[FILE-WORKSPACE-001] Return stays unbound and rename stays unavailable in Phase 4A")
    func returnKeyRemainsUnbound() {
        #expect(RemoteWorkspaceKeyboardCommand.all == [.openSelection, .goToParent])
        #expect(RemoteWorkspaceKeyboardCommand.all.allSatisfy { $0.key != .return })
        #expect(!RemoteWorkspaceKeyboardCommand.all.contains { $0.action == .renameSelection })
    }

    @Test("[MAC-001, TERM-KEY-002] terminal command routing is unchanged while a workspace route is active")
    func terminalCommandRoutingUnchangedWithActiveWorkspaceRoute() async throws {
        let fixture = try makeRemoteFixture()
        let store = makeRuntimeStore(
            fixture: fixture,
            closeDispositionResolver: { _ in .closeImmediately }
        )
        let router = TerminalCommandRouter()
        router.attach(workspace: store, closeWindow: {})
        store.createSSHTerminal()
        try await waitUntil { store.selectedRuntime != nil }
        let workspace = try #require(fixture.recordedWorkspaces.first)
        try await waitUntil { workspace.availability == .available }
        let owner = try #require(store.selectedRemoteWorkspaceFocusOwner)
        let route = RemoteWorkspaceCommandRoute(
            actions: RemoteWorkspaceFocusedActions.forRuntime(
                runtimeID: owner.runtimeID,
                workspace: workspace,
                pasteboard: RemotePathPasteboard(writer: CommandTestPasteboardWriter()),
                currentOwner: { [weak store] in store?.selectedRemoteWorkspaceFocusOwner }
            )
        )

        #expect(route.isEnabled(.refresh))
        #expect(router.canFindInTerminal)
        #expect(router.canCloseTerminal)
        router.findInTerminal()
        #expect(router.canCloseTerminal)

        router.closeTerminal()
        try await waitUntil { store.sessions.isEmpty }
        #expect(store.tabs.isEmpty)
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

    @MainActor
    private final class RemoteCommandFixture {
        let work: RemotePath
        let reports: RemoteFileEntry
        let broken: RemoteFileEntry
        let readme: RemoteFileEntry
        private let directoryGraph: [RemotePath: InMemoryRemoteFileProvider.Directory]
        private let deterministicResponses: InMemoryRemoteFileProvider.DeterministicResponses
        private(set) var recordedProviders: [InMemoryRemoteFileProvider] = []
        private(set) var recordedWorkspaces: [RemoteWorkspace] = []

        init(
            work: RemotePath,
            reports: RemoteFileEntry,
            broken: RemoteFileEntry,
            readme: RemoteFileEntry,
            directoryGraph: [RemotePath: InMemoryRemoteFileProvider.Directory],
            deterministicResponses: InMemoryRemoteFileProvider.DeterministicResponses
        ) {
            self.work = work
            self.reports = reports
            self.broken = broken
            self.readme = readme
            self.directoryGraph = directoryGraph
            self.deterministicResponses = deterministicResponses
        }

        func makeProvider() -> InMemoryRemoteFileProvider {
            let provider = InMemoryRemoteFileProvider(
                initialDirectory: work,
                directoryGraph: directoryGraph,
                deterministicResponses: deterministicResponses
            )
            recordedProviders.append(provider)
            return provider
        }

        func makeWorkspace() -> RemoteWorkspace {
            let workspace = RemoteWorkspace(provider: makeProvider())
            recordedWorkspaces.append(workspace)
            return workspace
        }
    }

    private func makeRemoteFixture() throws -> RemoteCommandFixture {
        let work = try path("/work")
        let reports = try entry("/work/reports", kind: .directory)
        let broken = try entry("/work/broken", kind: .directory)
        let readme = try entry("/work/readme.txt", kind: .regular)
        let summary = try entry("/work/reports/summary.txt", kind: .regular)
        return RemoteCommandFixture(
            work: work,
            reports: reports,
            broken: broken,
            readme: readme,
            directoryGraph: [
                try path("/"): .init(entries: [try entry("/work", kind: .directory)]),
                work: .init(entries: [reports, broken, readme]),
                reports.path: .init(entries: [summary])
            ],
            deterministicResponses: .init(
                listings: [
                    broken.path: .failure(RemoteFileError(category: .timeout))
                ]
            )
        )
    }

    private func makeRuntimeStore(
        fixture: RemoteCommandFixture,
        closeDispositionResolver: @escaping TerminalCloseDispositionResolver = {
            await $0.closeDisposition()
        }
    ) -> TerminalWorkspaceStore {
        TerminalWorkspaceStore(
            closeDispositionResolver: closeDispositionResolver,
            launchPreflight: { _ in },
            sessionFactory: { sessionID, specification in
                let process = WorkspaceTestTerminalProcess()
                let factory = SessionLaunchConfigurationFactory(
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
                )
                return TerminalSession(
                    sessionID: sessionID,
                    launchSpecification: specification,
                    configurationFactory: factory,
                    processLauncher: { _ in process }
                )
            },
            remoteWorkspaceFactory: { _, _ in fixture.makeWorkspace() }
        )
    }

    private func workspacePendingSettled(_ workspace: RemoteWorkspace) -> Bool {
        workspace.pendingDirectory == nil
            && workspace.activeRequestCount == 0
            && workspace.queuedRequestCount == 0
    }

    @MainActor
    private final class CommandTestPasteboardWriter: RemotePathPasteboardWriting {
        private(set) var writtenItems: [String] = []

        func writeSinglePlainTextItem(_ text: String) -> Bool {
            writtenItems.append(text)
            return true
        }
    }

    private func waitUntilAsync(
        _ condition: @escaping @MainActor () async -> Bool
    ) async throws {
        for _ in 0..<300 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for terminal workspace command result")
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
