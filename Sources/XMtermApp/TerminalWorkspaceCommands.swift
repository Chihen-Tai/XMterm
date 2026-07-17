import Observation
import SwiftUI
import XMtermCore
import XMtermRemote

/// App-scoped command route that weakly follows the single live window workspace.
///
/// The router survives window recreation, but never owns a workspace or reuses one after its
/// terminal sessions have been shut down.
@MainActor
@Observable
final class TerminalCommandRouter {
    @ObservationIgnored private weak var workspace: TerminalWorkspaceStore?
    @ObservationIgnored private var closeWindowAction: (@MainActor () -> Void)?
    @ObservationIgnored private var newTerminalAction: (@MainActor () -> Void)?
    @ObservationIgnored private var chooseSessionAction: (@MainActor () -> Void)?
    @ObservationIgnored private var manageSessionsAction: (@MainActor () -> Void)?
    private var bindingGeneration = 0

    var canCreateTerminal: Bool {
        _ = bindingGeneration
        return workspace?.canCreateTerminal ?? false
    }

    var canCloseTerminal: Bool {
        _ = bindingGeneration
        return workspace?.selectedSession != nil && workspace?.activeAlert == nil
    }

    var canFindInTerminal: Bool {
        _ = bindingGeneration
        return workspace?.selectedSession != nil
    }

    var canCloseWindow: Bool {
        _ = bindingGeneration
        return workspace != nil && closeWindowAction != nil
    }

    var canChooseSession: Bool {
        _ = bindingGeneration
        return canCreateTerminal && chooseSessionAction != nil
    }

    var canManageSessions: Bool {
        _ = bindingGeneration
        return workspace != nil && manageSessionsAction != nil
    }

    func attach(
        workspace: TerminalWorkspaceStore,
        closeWindow: @escaping @MainActor () -> Void,
        newTerminal: (@MainActor () -> Void)? = nil,
        chooseSession: (@MainActor () -> Void)? = nil,
        manageSessions: (@MainActor () -> Void)? = nil
    ) {
        self.workspace = workspace
        closeWindowAction = closeWindow
        newTerminalAction = newTerminal ?? { [weak workspace] in
            workspace?.createTerminal()
        }
        chooseSessionAction = chooseSession ?? { [weak workspace] in
            workspace?.createSSHTerminal()
        }
        manageSessionsAction = manageSessions
        bindingGeneration &+= 1
    }

    func detach(from workspace: TerminalWorkspaceStore) {
        guard self.workspace === workspace else { return }
        self.workspace = nil
        closeWindowAction = nil
        newTerminalAction = nil
        chooseSessionAction = nil
        manageSessionsAction = nil
        bindingGeneration &+= 1
    }

    func newTerminal() {
        guard canCreateTerminal else { return }
        newTerminalAction?()
    }

    func newSSHTerminal() {
        chooseSession()
    }

    func chooseSession() {
        guard canChooseSession else { return }
        chooseSessionAction?()
    }

    func manageSessions() {
        guard canManageSessions else { return }
        manageSessionsAction?()
    }

    func closeTerminal() {
        guard canCloseTerminal else { return }
        workspace?.requestCloseSelected()
    }

    func closeWindow() {
        guard canCloseWindow else { return }
        closeWindowAction?()
    }

    func findInTerminal() {
        guard canFindInTerminal else { return }
        workspace?.findInSelectedTerminal()
    }
}

/// One keyboard binding reserved for a focused remote-workspace action.
///
/// Return deliberately has no binding: it stays reserved for the future Finder-style
/// Rename and must not open or rename remote items in read-only Phase 4A.
struct RemoteWorkspaceKeyboardCommand: Equatable {
    let key: KeyEquivalent
    let modifiers: EventModifiers
    let action: RemoteWorkspaceAction

    static let openSelection = Self(
        key: .downArrow,
        modifiers: .command,
        action: .openSelection
    )

    static let goToParent = Self(
        key: .upArrow,
        modifiers: .command,
        action: .goToParent
    )

    static let all: [Self] = [.openSelection, .goToParent]

    var keyboardShortcut: KeyboardShortcut {
        KeyboardShortcut(key, modifiers: modifiers)
    }
}

/// Menu/command adapter over the focused actions published by the selected runtime's
/// Remote Workspace. A missing value or a stale focus owner disables every action.
@MainActor
struct RemoteWorkspaceCommandRoute {
    static let contextCopyActions = RemoteWorkspaceAction.copyActions

    private static let disabledPolicy = RemoteWorkspaceActionPolicy(
        availability: .idle,
        currentDirectory: nil,
        canGoBack: false,
        canGoForward: false,
        selectedEntry: nil
    )

    private let actions: RemoteWorkspaceFocusedActions?

    init(actions: RemoteWorkspaceFocusedActions?) {
        self.actions = actions
    }

    func isEnabled(_ action: RemoteWorkspaceAction) -> Bool {
        guard let actions, actions.isOwnerCurrent else { return false }
        return actions.policy.isEnabled(action)
    }

    @discardableResult
    func perform(_ action: RemoteWorkspaceAction) -> Bool {
        actions?.perform(action) ?? false
    }

    func presentation(
        for action: RemoteWorkspaceAction
    ) -> RemoteWorkspaceActionPresentation {
        guard let actions, actions.isOwnerCurrent else {
            return Self.disabledPolicy.presentation(for: action)
        }
        return actions.policy.presentation(for: action)
    }
}

/// Maps enabled focused actions onto the exact owning runtime's workspace methods and
/// the plain-text pasteboard adapter. It never executes a shell and never logs paths.
@MainActor
struct RemoteWorkspaceActionPerformer {
    private let workspace: RemoteWorkspace
    private let pasteboard: RemotePathPasteboard

    init(workspace: RemoteWorkspace, pasteboard: RemotePathPasteboard) {
        self.workspace = workspace
        self.pasteboard = pasteboard
    }

    var selectedListingEntry: RemoteFileEntry? {
        guard let selected = workspace.selectedEntry else { return nil }
        return workspace.currentListing?.entries.first { $0.path == selected }
    }

    func currentPolicy() -> RemoteWorkspaceActionPolicy {
        contextPolicy(for: selectedListingEntry)
    }

    func contextPolicy(
        for entry: RemoteFileEntry?
    ) -> RemoteWorkspaceActionPolicy {
        RemoteWorkspaceActionPolicy(
            availability: workspace.availability,
            currentDirectory: workspace.currentDirectory,
            canGoBack: workspace.canGoBack,
            canGoForward: workspace.canGoForward,
            selectedEntry: entry,
            retryDirectoryState: retryDirectoryState(for: entry)
        )
    }

    func perform(_ action: RemoteWorkspaceAction) {
        switch action {
        case .goBack:
            workspace.goBack()
        case .goForward:
            workspace.goForward()
        case .goToParent:
            workspace.goToParent()
        case .refresh:
            workspace.refresh()
        case .openSelection:
            guard let selected = workspace.selectedEntry else { return }
            workspace.openDirectory(selected)
        case .retryWorkspace:
            workspace.retry()
        case .retryDirectory:
            guard let target = retryDirectoryTarget(for: selectedListingEntry) else {
                return
            }
            workspace.retryDirectory(target)
        case .copyPath, .copyName, .copyParentDirectory, .copyShellQuotedPath:
            guard let copyAction = action.copyAction,
                  let target = workspace.selectedEntry ?? workspace.currentDirectory else {
                return
            }
            pasteboard.copy(copyAction, from: target)
        case .renameSelection:
            break
        }
    }

    /// Context-menu copy for an explicit clicked target, gated by the same
    /// availability and lossless-text rules as the shared action policy.
    @discardableResult
    func performContextCopy(
        _ action: RemoteWorkspaceAction,
        target: RemotePath
    ) -> Bool {
        guard workspace.availability == .available,
              let copyAction = action.copyAction else { return false }
        return pasteboard.copy(copyAction, from: target)
    }

    private func retryDirectoryTarget(
        for entry: RemoteFileEntry?
    ) -> RemotePath? {
        guard let entry, entry.kind == .directory,
              workspace.expandedDirectories.contains(entry.path) else { return nil }
        return entry.path
    }

    private func retryDirectoryState(
        for entry: RemoteFileEntry?
    ) -> RemoteDirectoryLoadState? {
        retryDirectoryTarget(for: entry).flatMap { workspace.directoryStates[$0] }
    }
}

extension RemoteWorkspaceFocusedActions {
    /// Builds the focused actions for one exact launched runtime and its workspace.
    @MainActor
    static func forRuntime(
        runtimeID: TerminalSessionID,
        workspace: RemoteWorkspace,
        pasteboard: RemotePathPasteboard,
        currentOwner: @escaping @MainActor () -> RemoteWorkspaceFocusOwner?
    ) -> RemoteWorkspaceFocusedActions {
        let performer = RemoteWorkspaceActionPerformer(
            workspace: workspace,
            pasteboard: pasteboard
        )
        return RemoteWorkspaceFocusedActions(
            owner: RemoteWorkspaceFocusOwner(
                runtimeID: runtimeID,
                workspaceID: workspace.id
            ),
            policy: performer.currentPolicy(),
            currentOwner: currentOwner,
            perform: performer.perform
        )
    }
}

extension TerminalWorkspaceStore {
    /// Exact focus-owner identity of the selected runtime's workspace; nil for local
    /// runtimes and empty selection so stale actions can never match.
    var selectedRemoteWorkspaceFocusOwner: RemoteWorkspaceFocusOwner? {
        guard let runtime = selectedRuntime,
              let workspace = runtime.remoteWorkspace else { return nil }
        return RemoteWorkspaceFocusOwner(
            runtimeID: runtime.id,
            workspaceID: workspace.id
        )
    }
}

struct TerminalCommands: Commands {
    let router: TerminalCommandRouter
    @FocusedValue(\.remoteWorkspaceActions) private var remoteWorkspaceActions

    private var remoteRoute: RemoteWorkspaceCommandRoute {
        RemoteWorkspaceCommandRoute(actions: remoteWorkspaceActions)
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Terminal") {
                router.newTerminal()
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(!router.canCreateTerminal)

            Button("Choose Session…") {
                router.chooseSession()
            }
            .disabled(!router.canChooseSession)

            Button("Manage Sessions…") {
                router.manageSessions()
            }
            .disabled(!router.canManageSessions)
        }

        CommandMenu("Terminal") {
            Button("Find in Terminal…") {
                router.findInTerminal()
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(!router.canFindInTerminal)

            Divider()

            Button("Close Terminal") {
                router.closeTerminal()
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(!router.canCloseTerminal)

            Button("Close Window") {
                router.closeWindow()
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
            .disabled(!router.canCloseWindow)
        }

        CommandMenu("Remote") {
            remoteCommandButton(.goBack, shortcut: KeyboardShortcut("[", modifiers: .command))
            remoteCommandButton(.goForward, shortcut: KeyboardShortcut("]", modifiers: .command))
            remoteCommandButton(
                .goToParent,
                shortcut: RemoteWorkspaceKeyboardCommand.goToParent.keyboardShortcut
            )
            remoteCommandButton(
                .openSelection,
                shortcut: RemoteWorkspaceKeyboardCommand.openSelection.keyboardShortcut
            )

            Divider()

            remoteCommandButton(.refresh, shortcut: KeyboardShortcut("r", modifiers: .command))

            Divider()

            remoteCommandButton(.copyPath)
            remoteCommandButton(.copyName)
            remoteCommandButton(.copyParentDirectory)
            remoteCommandButton(.copyShellQuotedPath)
        }
    }

    @ViewBuilder
    private func remoteCommandButton(
        _ action: RemoteWorkspaceAction,
        shortcut: KeyboardShortcut? = nil
    ) -> some View {
        let route = remoteRoute
        let presentation = route.presentation(for: action)
        let button = Button(presentation.title) {
            route.perform(action)
        }
        .disabled(!route.isEnabled(action))
        .help(presentation.help)
        .accessibilityLabel(presentation.accessibilityLabel)

        if let shortcut {
            button.keyboardShortcut(shortcut)
        } else {
            button
        }
    }
}
