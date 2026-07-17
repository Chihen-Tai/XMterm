import XMtermCore

/// Orders saved-profile validation, immutable workspace publication, and recent metadata.
@MainActor
struct SessionProfileLaunchCoordinator {
    let profileStore: SessionProfileStore
    let workspace: TerminalWorkspaceStore

    func launch(
        _ id: SessionProfileID,
        onRuntimePublished: @MainActor () -> Void = {}
    ) async -> Bool {
        guard let profile = await profileStore.profileReadyForLaunch(id: id) else {
            return false
        }
        guard workspace.openProfile(profile) else { return false }

        // Release picker/focus presentation as soon as the immutable tab/session
        // pair exists, while keeping recency persistence owned by this launch task.
        onRuntimePublished()
        _ = await profileStore.recordOpened(id: id)
        return true
    }
}
