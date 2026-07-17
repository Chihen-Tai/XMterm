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

    private let currentOwner: @MainActor () -> RemoteWorkspaceFocusOwner?
    private let actionHandler: @MainActor (RemoteWorkspaceAction) -> Void

    init(
        owner: RemoteWorkspaceFocusOwner,
        policy: RemoteWorkspaceActionPolicy,
        currentOwner: @escaping @MainActor () -> RemoteWorkspaceFocusOwner?,
        perform: @escaping @MainActor (RemoteWorkspaceAction) -> Void
    ) {
        self.owner = owner
        self.policy = policy
        self.currentOwner = currentOwner
        actionHandler = perform
    }

    @MainActor
    @discardableResult
    func perform(_ action: RemoteWorkspaceAction) -> Bool {
        guard currentOwner() == owner,
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
