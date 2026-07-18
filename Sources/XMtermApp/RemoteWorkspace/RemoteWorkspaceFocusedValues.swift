import SwiftUI
import XMtermCore
import XMtermRemote

struct RemoteWorkspaceFocusOwner: Equatable, Hashable, Sendable {
    let runtimeID: TerminalSessionID
    let workspaceID: RemoteWorkspaceID
}

struct RemoteWorkspaceFocusedActions {
    let owner: RemoteWorkspaceFocusOwner
    let policy: RemoteWorkspaceActionPolicy

    private let workspaceHasFocus: @MainActor () -> Bool
    private let currentOwner: @MainActor () -> RemoteWorkspaceFocusOwner?
    private let actionHandler: @MainActor (RemoteWorkspaceAction) -> Void

    init(
        owner: RemoteWorkspaceFocusOwner,
        policy: RemoteWorkspaceActionPolicy,
        isWorkspaceFocused: @escaping @MainActor () -> Bool,
        currentOwner: @escaping @MainActor () -> RemoteWorkspaceFocusOwner?,
        perform: @escaping @MainActor (RemoteWorkspaceAction) -> Void
    ) {
        self.owner = owner
        self.policy = policy
        workspaceHasFocus = isWorkspaceFocused
        self.currentOwner = currentOwner
        actionHandler = perform
    }

    /// Whether the Remote Workspace interaction surface currently owns keyboard
    /// focus. Keyboard-shortcut and menu routing require this; direct sidebar
    /// controls and context menus do not.
    @MainActor
    var hasWorkspaceFocus: Bool {
        workspaceHasFocus()
    }

    @MainActor
    var isOwnerCurrent: Bool {
        currentOwner() == owner
    }

    @MainActor
    @discardableResult
    func perform(_ action: RemoteWorkspaceAction) -> Bool {
        guard isOwnerCurrent,
              policy.isEnabled(action) else { return false }
        actionHandler(action)
        return true
    }
}

private struct RemoteWorkspaceFocusedActionsKey: FocusedValueKey {
    typealias Value = RemoteWorkspaceFocusedActions
}

extension FocusedValues {
    var remoteWorkspaceActions: RemoteWorkspaceFocusedActions? {
        get { self[RemoteWorkspaceFocusedActionsKey.self] }
        set { self[RemoteWorkspaceFocusedActionsKey.self] = newValue }
    }
}
