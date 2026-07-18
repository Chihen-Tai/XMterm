import SwiftUI
import XMtermCore
import XMtermRemote

/// Thin routing seam between sidebar controls and the exact selected workspace.
///
/// Every pointer, keyboard, disclosure, breadcrumb, and retry interaction in the
/// sidebar goes through this value, so command routing stays testable without
/// instantiating SwiftUI views.
@MainActor
struct RemoteWorkspaceSidebarInteraction {
    let workspace: RemoteWorkspace

    func select(_ path: RemotePath?) {
        workspace.selectEntry(path)
    }

    /// Double-click open. The workspace itself ignores non-directory paths, so
    /// files stay inert in read-only Phase 4A.
    func openEntry(_ path: RemotePath) {
        workspace.openDirectory(path)
    }

    func setExpanded(_ path: RemotePath, isExpanded: Bool) {
        workspace.setExpanded(path, isExpanded: isExpanded)
    }

    func openBreadcrumb(_ path: RemotePath) {
        workspace.openBreadcrumb(path)
    }

    func retryDirectory(_ path: RemotePath) {
        workspace.retryDirectory(path)
    }
}

/// Remote Workspace sidebar content for the currently selected runtime.
///
/// Local runtimes show an explicit no-workspace explanation, an empty selection
/// shows a neutral state, and an SSH runtime shows exactly its own workspace.
struct RemoteWorkspaceSidebar: View {
    let store: TerminalWorkspaceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Remote Workspace")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .accessibilityAddTraits(.isHeader)
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if let runtime = store.selectedRuntime {
            if let workspace = runtime.remoteWorkspace {
                RemoteWorkspaceRuntimeView(
                    runtimeID: runtime.id,
                    workspace: workspace,
                    currentOwner: { [weak store] in
                        store?.selectedRemoteWorkspaceFocusOwner
                    }
                )
                .id(workspace.id)
            } else {
                RemoteWorkspaceUnavailableView(
                    message: RemoteWorkspacePresentation.localSessionExplanation
                )
            }
        } else {
            RemoteWorkspaceUnavailableView(
                message: "Open a session to browse its remote files"
            )
        }
    }
}

private struct RemoteWorkspaceUnavailableView: View {
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "server.rack")
                .font(.title3)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
        .accessibilityElement(children: .combine)
    }
}

/// The workspace presentation for one exact SSH runtime. The view observes only the
/// injected workspace; publishing focused actions is scoped to this view's lifetime,
/// so switching to another tab removes them immediately.
private struct RemoteWorkspaceRuntimeView: View {
    let runtimeID: TerminalSessionID
    let workspace: RemoteWorkspace
    let currentOwner: @MainActor () -> RemoteWorkspaceFocusOwner?

    /// True while the workspace listing owns keyboard focus. Keyboard-shortcut
    /// and menu routing require this; direct sidebar controls do not.
    @FocusState private var isListingFocused: Bool

    private let pasteboard = RemotePathPasteboard(
        writer: AppKitRemotePathPasteboardWriter()
    )

    private var performer: RemoteWorkspaceActionPerformer {
        RemoteWorkspaceActionPerformer(workspace: workspace, pasteboard: pasteboard)
    }

    private var interaction: RemoteWorkspaceSidebarInteraction {
        RemoteWorkspaceSidebarInteraction(workspace: workspace)
    }

    private var focusedActions: RemoteWorkspaceFocusedActions {
        .forRuntime(
            runtimeID: runtimeID,
            workspace: workspace,
            pasteboard: pasteboard,
            isWorkspaceFocused: { isListingFocused },
            currentOwner: currentOwner
        )
    }

    private var policy: RemoteWorkspaceActionPolicy {
        performer.currentPolicy()
    }

    private var workspaceStatus: RemoteWorkspaceStatusPresentation {
        RemoteWorkspacePresentation.workspaceStatus(for: workspace.availability)
    }

    private var currentDirectoryState: RemoteDirectoryLoadState? {
        workspace.currentDirectory.flatMap { workspace.directoryStates[$0] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            availabilityContent
        }
        .focusedValue(\.remoteWorkspaceActions, focusedActions)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Remote Workspace")
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            simulatedBadgeView
            HStack(spacing: 2) {
                navigationButton(.goBack, systemImage: "chevron.backward")
                navigationButton(.goForward, systemImage: "chevron.forward")
                navigationButton(.goToParent, systemImage: "arrow.up")
                Spacer(minLength: 4)
                navigationButton(.refresh, systemImage: "arrow.clockwise")
            }
            statusLine
            breadcrumbs
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    /// Rendered in the always-visible header for every availability state, so it
    /// persists across navigation, refresh, history, and breadcrumb moves.
    @ViewBuilder
    private var simulatedBadgeView: some View {
        if let badge = RemoteWorkspacePresentation.simulatedBadge(
            for: workspace.providerMode
        ) {
            HStack(spacing: 6) {
                Text(badge.title)
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .foregroundStyle(.orange)
                    .background(.orange.opacity(0.18), in: Capsule())
                Text(badge.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .help(badge.accessibilityLabel)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(badge.accessibilityLabel)
        }
    }

    private func navigationButton(
        _ action: RemoteWorkspaceAction,
        systemImage: String
    ) -> some View {
        let presentation = policy.presentation(for: action)
        return Button {
            _ = focusedActions.perform(action)
        } label: {
            Image(systemName: systemImage)
        }
        .buttonStyle(.borderless)
        .disabled(!presentation.isEnabled)
        .help(presentation.help)
        .accessibilityLabel(presentation.accessibilityLabel)
    }

    @ViewBuilder
    private var statusLine: some View {
        let status = currentStatus
        HStack(spacing: 5) {
            if status.showsProgress {
                ProgressView()
                    .controlSize(.mini)
            }
            Text(status.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .help(status.detail ?? status.title)
        .accessibilityElement(children: .combine)
    }

    private var currentStatus: RemoteWorkspaceStatusPresentation {
        guard workspace.availability == .available else {
            return workspaceStatus
        }
        guard let currentDirectoryState else {
            return workspaceStatus
        }
        return RemoteWorkspacePresentation.directoryStatus(for: currentDirectoryState)
    }

    @ViewBuilder
    private var breadcrumbs: some View {
        if let currentDirectory = workspace.currentDirectory {
            let paths = currentDirectory.breadcrumbPaths
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(paths.enumerated()), id: \.element) { index, path in
                        if index > 0 {
                            Image(systemName: "chevron.compact.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        breadcrumbButton(path, isCurrent: index == paths.count - 1)
                    }
                }
            }
            .accessibilityLabel("Remote path")
        }
    }

    private func breadcrumbButton(_ path: RemotePath, isCurrent: Bool) -> some View {
        Button {
            interaction.openBreadcrumb(path)
        } label: {
            Text(path.components.last?.escapedDisplayString ?? "/")
                .font(.caption)
                .fontWeight(isCurrent ? .semibold : .regular)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .disabled(isCurrent || workspace.availability != .available)
        .help(path.escapedDisplayString)
        .accessibilityLabel(
            RemoteWorkspacePresentation.breadcrumbAccessibilityLabel(for: path)
        )
    }

    // MARK: Availability states

    @ViewBuilder
    private var availabilityContent: some View {
        switch workspace.availability {
        case .idle, .connecting, .loadingInitialDirectory, .closing, .closed:
            statusPlaceholder
        case .failed:
            failureContent
        case .available:
            listingContent
        }
    }

    private var statusPlaceholder: some View {
        VStack(spacing: 8) {
            if workspaceStatus.showsProgress {
                ProgressView()
                    .controlSize(.small)
            }
            Text(workspaceStatus.title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
        .accessibilityElement(children: .combine)
    }

    private var failureContent: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title3)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(workspaceStatus.title)
                .font(.callout)
                .multilineTextAlignment(.center)
            if let detail = workspaceStatus.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if policy.isEnabled(.retryWorkspace) {
                Button(policy.presentation(for: .retryWorkspace).title) {
                    _ = focusedActions.perform(.retryWorkspace)
                }
                .help(policy.presentation(for: .retryWorkspace).help)
                .accessibilityLabel(
                    policy.presentation(for: .retryWorkspace).accessibilityLabel
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
    }

    // MARK: Listing

    @ViewBuilder
    private var listingContent: some View {
        if let listing = workspace.currentListing, listing.entries.isEmpty {
            VStack(spacing: 8) {
                Text(
                    RemoteWorkspacePresentation
                        .directoryStatus(for: .empty(listing)).title
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(16)
            .contentShape(Rectangle())
            .contextMenu {
                contextMenuItems(clicked: nil)
            }
        } else {
            listingList
        }
    }

    private var listingList: some View {
        List(selection: selectionBinding) {
            ForEach(workspace.visibleProjection.rows) { row in
                listingRow(row)
            }
        }
        .listStyle(.sidebar)
        .focused($isListingFocused)
        .contextMenu(forSelectionType: RemotePath.self) { selection in
            contextMenuItems(clicked: selection.first)
        } primaryAction: { selection in
            for path in selection {
                interaction.openEntry(path)
            }
        }
        .accessibilityLabel("Remote files")
    }

    @ViewBuilder
    private func listingRow(_ row: RemoteWorkspaceVisibleRow) -> some View {
        switch row.kind {
        case let .entry(entry, isExpanded, childState):
            // Every visible loaded entry at any depth is a true selectable row;
            // the workspace validates selection against the same projection.
            RemoteEntryRow(
                entry: entry,
                depth: row.depth,
                isExpanded: isExpanded,
                childState: childState,
                toggleDisclosure: { expanded in
                    interaction.setExpanded(entry.path, isExpanded: expanded)
                }
            )
            .tag(entry.path)
        case let .childStatus(path, state, allowsRetry):
            RemoteEntryChildStatusRow(
                state: state,
                depth: row.depth,
                isRetryEnabled: allowsRetry && isChildRetryEnabled(state),
                retry: { interaction.retryDirectory(path) }
            )
        }
    }

    private var selectionBinding: Binding<RemotePath?> {
        Binding(
            get: { workspace.selectedEntry },
            set: { interaction.select($0) }
        )
    }

    @ViewBuilder
    private func contextMenuItems(clicked: RemotePath?) -> some View {
        let entry = clicked.flatMap { workspace.visibleProjection.entry(for: $0) }
        let target = entry?.path ?? workspace.currentDirectory
        let menuPolicy = performer.contextPolicy(for: entry)
        ForEach(RemoteWorkspaceCommandRoute.contextCopyActions, id: \.self) { action in
            let presentation = menuPolicy.presentation(for: action)
            Button(presentation.title) {
                guard let target else { return }
                performer.performContextCopy(action, target: target)
            }
            .disabled(!presentation.isEnabled || target == nil)
            .help(presentation.help)
            .accessibilityLabel(presentation.accessibilityLabel)
        }
    }

    private func isChildRetryEnabled(_ state: RemoteDirectoryLoadState) -> Bool {
        RemoteWorkspaceActionPolicy(
            availability: workspace.availability,
            currentDirectory: workspace.currentDirectory,
            canGoBack: workspace.canGoBack,
            canGoForward: workspace.canGoForward,
            selectedEntry: nil,
            retryDirectoryState: state
        ).isEnabled(.retryDirectory)
    }

}
