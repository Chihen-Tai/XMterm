import Foundation
import Testing
import XMtermCore
import XMtermRemote
@testable import XMtermApp

@Suite("Remote workspace sidebar policy")
@MainActor
struct RemoteWorkspaceSidebarPolicyTests {
    @Test("[FILE-NAV-002, MAC-001] available actions derive from one immutable policy")
    func availableActionsUseSharedPolicy() throws {
        let selectedDirectory = try entry("/work/reports", kind: .directory)
        let policy = RemoteWorkspaceActionPolicy(
            availability: .available,
            currentDirectory: try path("/work"),
            canGoBack: true,
            canGoForward: true,
            selectedEntry: selectedDirectory
        )

        for action in [
            RemoteWorkspaceAction.goBack,
            .goForward,
            .goToParent,
            .refresh,
            .openSelection,
            .copyPath,
            .copyName,
            .copyParentDirectory,
            .copyShellQuotedPath
        ] {
            #expect(policy.isEnabled(action))
            #expect(policy.presentation(for: action).isEnabled)
            #expect(!policy.presentation(for: action).title.isEmpty)
            #expect(!policy.presentation(for: action).help.isEmpty)
            #expect(!policy.presentation(for: action).accessibilityLabel.isEmpty)
        }
    }

    @Test("[FILE-NAV-002] unavailable and loading workspaces disable navigation")
    func unavailableStatesDisableNavigation() throws {
        for availability in [
            RemoteWorkspaceAvailability.idle,
            .connecting,
            .loadingInitialDirectory,
            .closing,
            .closed
        ] {
            let policy = RemoteWorkspaceActionPolicy(
                availability: availability,
                currentDirectory: try path("/work"),
                canGoBack: true,
                canGoForward: true,
                selectedEntry: try entry("/work/reports", kind: .directory)
            )

            #expect(!policy.isEnabled(.goBack))
            #expect(!policy.isEnabled(.goForward))
            #expect(!policy.isEnabled(.goToParent))
            #expect(!policy.isEnabled(.refresh))
            #expect(!policy.isEnabled(.openSelection))
        }
    }

    @Test("[FILE-NAV-002] root disables Parent while retaining Refresh")
    func rootBehaviorIsExplicit() {
        let policy = RemoteWorkspaceActionPolicy(
            availability: .available,
            currentDirectory: .root,
            canGoBack: false,
            canGoForward: false,
            selectedEntry: nil
        )

        #expect(!policy.isEnabled(.goToParent))
        #expect(policy.isEnabled(.refresh))
        #expect(policy.isEnabled(.copyPath))
        #expect(!policy.isEnabled(.copyName))
        #expect(!policy.isEnabled(.copyParentDirectory))
        #expect(policy.isEnabled(.copyShellQuotedPath))
    }

    @Test("[FILE-WORKSPACE-001, FILE-NAV-002] files and symlinks have no open action")
    func onlyDirectoriesCanOpen() throws {
        for kind in [
            RemoteFileEntry.Kind.regular,
            .symbolicLink,
            .other
        ] {
            let policy = RemoteWorkspaceActionPolicy(
                availability: .available,
                currentDirectory: try path("/work"),
                canGoBack: false,
                canGoForward: false,
                selectedEntry: try entry("/work/item-\(kind.rawValue)", kind: kind)
            )
            #expect(!policy.isEnabled(.openSelection))
        }
    }

    @Test("[FILE-STATE-001] retry is enabled only where it can perform useful work")
    func retryAvailabilityIsHonest() throws {
        let timeout = RemoteFileError(category: .timeout)
        let blocked = RemoteFileError(category: .transportUnavailable)
        let current = try path("/work")
        let retryableWorkspace = RemoteWorkspaceActionPolicy(
            availability: .failed(timeout),
            currentDirectory: nil,
            canGoBack: false,
            canGoForward: false,
            selectedEntry: nil
        )
        let blockedWorkspace = RemoteWorkspaceActionPolicy(
            availability: .failed(blocked),
            currentDirectory: nil,
            canGoBack: false,
            canGoForward: false,
            selectedEntry: nil
        )
        let failedDirectory = RemoteWorkspaceActionPolicy(
            availability: .available,
            currentDirectory: current,
            canGoBack: false,
            canGoForward: false,
            selectedEntry: nil,
            retryDirectoryState: .failed(error: timeout, previousListing: nil)
        )
        let cancelledDirectory = RemoteWorkspaceActionPolicy(
            availability: .available,
            currentDirectory: current,
            canGoBack: false,
            canGoForward: false,
            selectedEntry: nil,
            retryDirectoryState: .cancelled(previousListing: nil)
        )

        #expect(retryableWorkspace.isEnabled(.retryWorkspace))
        #expect(!blockedWorkspace.isEnabled(.retryWorkspace))
        #expect(failedDirectory.isEnabled(.retryDirectory))
        #expect(cancelledDirectory.isEnabled(.retryDirectory))
    }

    @Test("[FILE-COPY-001] lossy path identity disables all exact copy actions")
    func lossyPathDisablesCopy() throws {
        let lossyPath = try RemotePath(rawBytes: [0x2F, 0x80])
        let lossyEntry = try RemoteFileEntry(path: lossyPath, kind: .regular)
        let policy = RemoteWorkspaceActionPolicy(
            availability: .available,
            currentDirectory: .root,
            canGoBack: false,
            canGoForward: false,
            selectedEntry: lossyEntry
        )

        for action in RemoteWorkspaceAction.copyActions {
            #expect(!policy.isEnabled(action))
        }
    }

    @Test("[FILE-WORKSPACE-001] Return remains unused in read-only Phase 4A")
    func returnDoesNotRenameOrOpen() throws {
        let policy = RemoteWorkspaceActionPolicy(
            availability: .available,
            currentDirectory: try path("/work"),
            canGoBack: false,
            canGoForward: false,
            selectedEntry: try entry("/work/reports", kind: .directory)
        )

        #expect(!policy.isEnabled(.renameSelection))
        #expect(!policy.handlesReturnKey)
    }

    @Test("[SESS-011, MAC-001] focused actions reject a stale tab owner")
    func focusedActionsGuardExactRuntimeOwnership() throws {
        let firstOwner = RemoteWorkspaceFocusOwner(
            runtimeID: TerminalSessionID(),
            workspaceID: RemoteWorkspaceID()
        )
        let secondOwner = RemoteWorkspaceFocusOwner(
            runtimeID: TerminalSessionID(),
            workspaceID: RemoteWorkspaceID()
        )
        var selectedOwner: RemoteWorkspaceFocusOwner? = firstOwner
        var performed: [RemoteWorkspaceAction] = []
        let policy = RemoteWorkspaceActionPolicy(
            availability: .available,
            currentDirectory: try path("/work"),
            canGoBack: false,
            canGoForward: false,
            selectedEntry: nil
        )
        let focusedActions = RemoteWorkspaceFocusedActions(
            owner: firstOwner,
            policy: policy,
            isWorkspaceFocused: { true },
            currentOwner: { selectedOwner },
            perform: { performed.append($0) }
        )

        #expect(focusedActions.perform(.refresh))
        #expect(performed == [.refresh])

        selectedOwner = secondOwner
        #expect(!focusedActions.perform(.refresh))
        #expect(performed == [.refresh])
    }

    @Test("[MAC-001] focused actions also reject disabled actions")
    func focusedActionsEnforcePolicy() {
        let owner = RemoteWorkspaceFocusOwner(
            runtimeID: TerminalSessionID(),
            workspaceID: RemoteWorkspaceID()
        )
        var performed: [RemoteWorkspaceAction] = []
        let policy = RemoteWorkspaceActionPolicy(
            availability: .available,
            currentDirectory: .root,
            canGoBack: false,
            canGoForward: false,
            selectedEntry: nil
        )
        let focusedActions = RemoteWorkspaceFocusedActions(
            owner: owner,
            policy: policy,
            isWorkspaceFocused: { true },
            currentOwner: { owner },
            perform: { performed.append($0) }
        )

        #expect(!focusedActions.perform(.goToParent))
        #expect(!focusedActions.perform(.renameSelection))
        #expect(performed.isEmpty)
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
}
