import Foundation
import XMtermRemote

struct RemoteWorkspaceStatusPresentation: Equatable, Sendable {
    let title: String
    let detail: String?
    let showsProgress: Bool

    init(
        title: String,
        detail: String? = nil,
        showsProgress: Bool = false
    ) {
        self.title = title
        self.detail = detail
        self.showsProgress = showsProgress
    }
}

/// Trusted developer-badge copy shown whenever the workspace's composition-
/// assigned provider mode is the simulated fixture. Derived from
/// `RemoteProviderMode` only — never from provider text or paths.
struct RemoteWorkspaceBadgePresentation: Equatable, Sendable {
    let title: String
    let detail: String
    let accessibilityLabel: String
}

struct RemoteEntryMetadataPresentation: Equatable, Sendable {
    let kindText: String
    let sizeText: String?
    let modificationText: String?
    let permissionsText: String?
    let completenessText: String
}

enum RemoteWorkspacePresentation {
    static let localSessionExplanation =
        "Remote Workspace is available for SSH sessions"

    static func workspaceStatus(
        for availability: RemoteWorkspaceAvailability
    ) -> RemoteWorkspaceStatusPresentation {
        switch availability {
        case .idle:
            RemoteWorkspaceStatusPresentation(title: "Remote Workspace idle")
        case .connecting:
            RemoteWorkspaceStatusPresentation(
                title: "Connecting to Remote Workspace…",
                showsProgress: true
            )
        case .loadingInitialDirectory:
            RemoteWorkspaceStatusPresentation(
                title: "Loading initial remote directory…",
                showsProgress: true
            )
        case .available:
            RemoteWorkspaceStatusPresentation(title: "Remote Workspace ready")
        case let .failed(error) where error.category == .transportUnavailable:
            RemoteWorkspaceStatusPresentation(
                title: "Remote file transport unavailable",
                detail: error.userFacingMessage
            )
        case let .failed(error):
            RemoteWorkspaceStatusPresentation(
                title: "Remote Workspace unavailable",
                detail: error.userFacingMessage
            )
        case .closing:
            RemoteWorkspaceStatusPresentation(
                title: "Closing Remote Workspace…",
                showsProgress: true
            )
        case .closed:
            RemoteWorkspaceStatusPresentation(title: "Remote Workspace closed")
        }
    }

    static func simulatedBadge(
        for mode: RemoteProviderMode
    ) -> RemoteWorkspaceBadgePresentation? {
        switch mode {
        case .production, .unavailable, .packageTest:
            nil
        case .simulatedDeveloperFixture:
            RemoteWorkspaceBadgePresentation(
                title: "SIMULATED",
                detail: "Developer fixture — not a real remote host",
                accessibilityLabel:
                    "Simulated developer fixture. This listing is not a real remote host."
            )
        }
    }

    static func directoryStatus(
        for state: RemoteDirectoryLoadState
    ) -> RemoteWorkspaceStatusPresentation {
        switch state {
        case .notLoaded:
            RemoteWorkspaceStatusPresentation(title: "Not loaded")
        case .loading(previousListing: nil):
            RemoteWorkspaceStatusPresentation(
                title: "Loading directory…",
                showsProgress: true
            )
        case .loading(previousListing: .some):
            RemoteWorkspaceStatusPresentation(
                title: "Refreshing directory…",
                showsProgress: true
            )
        case let .loaded(listing):
            RemoteWorkspaceStatusPresentation(
                title: itemCountText(listing.entries.count)
            )
        case .empty:
            RemoteWorkspaceStatusPresentation(title: "This directory is empty")
        case let .failed(error, _):
            RemoteWorkspaceStatusPresentation(
                title: "Couldn’t load this directory",
                detail: error.userFacingMessage
            )
        case .cancelled:
            RemoteWorkspaceStatusPresentation(
                title: "Directory loading cancelled"
            )
        }
    }

    static func displayName(for entry: RemoteFileEntry) -> String {
        entry.name.escapedDisplayString
    }

    static func metadata(
        for entry: RemoteFileEntry
    ) -> RemoteEntryMetadataPresentation {
        RemoteEntryMetadataPresentation(
            kindText: kindText(for: entry.kind),
            sizeText: entry.size.map { "\($0) bytes" },
            modificationText: entry.modificationDate.map(utcDateText),
            permissionsText: entry.permissions.map(permissionText),
            completenessText: completenessText(entry.metadataCompleteness)
        )
    }

    static func entryAccessibilityLabel(
        for entry: RemoteFileEntry,
        directoryState: RemoteDirectoryLoadState? = nil
    ) -> String {
        var components = [displayName(for: entry), kindText(for: entry.kind)]
        if entry.kind == .directory, let directoryState {
            components.append(directoryStatus(for: directoryState).title)
        }
        return components.joined(separator: ", ")
    }

    static func breadcrumbAccessibilityLabel(for path: RemotePath) -> String {
        "Remote directory \(path.escapedDisplayString)"
    }

    static func kindText(for kind: RemoteFileEntry.Kind) -> String {
        switch kind {
        case .directory: "Folder"
        case .regular: "File"
        case .symbolicLink: "Symbolic link"
        case .other: "Other item"
        }
    }

    private static func itemCountText(_ count: Int) -> String {
        count == 1 ? "1 item" : "\(count) items"
    }

    private static func permissionText(_ permissions: UInt16) -> String {
        let octal = String(permissions, radix: 8)
        return String(repeating: "0", count: max(0, 4 - octal.count)) + octal
    }

    private static func completenessText(
        _ completeness: RemoteMetadataCompleteness
    ) -> String {
        switch completeness {
        case .complete: "Metadata complete"
        case .partial: "Metadata incomplete"
        }
    }

    private static func utcDateText(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        return String(
            format: "%04d-%02d-%02d %02d:%02d:%02d UTC",
            locale: Locale(identifier: "en_US_POSIX"),
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0,
            parts.hour ?? 0,
            parts.minute ?? 0,
            parts.second ?? 0
        )
    }
}

enum RemoteWorkspaceAction: CaseIterable, Equatable, Hashable, Sendable {
    case goBack
    case goForward
    case goToParent
    case refresh
    case openSelection
    case retryWorkspace
    case retryDirectory
    case copyPath
    case copyName
    case copyParentDirectory
    case copyShellQuotedPath
    case renameSelection

    static let copyActions: [Self] = [
        .copyPath,
        .copyName,
        .copyParentDirectory,
        .copyShellQuotedPath
    ]

    var copyAction: RemotePathCopyAction? {
        switch self {
        case .copyPath: .path
        case .copyName: .name
        case .copyParentDirectory: .parentDirectory
        case .copyShellQuotedPath: .shellQuotedPath
        default: nil
        }
    }
}

struct RemoteWorkspaceActionPresentation: Equatable, Sendable {
    let title: String
    let help: String
    let accessibilityLabel: String
    let isEnabled: Bool
}

struct RemoteWorkspaceActionPolicy: Equatable, Sendable {
    private let enabledActions: Set<RemoteWorkspaceAction>

    let handlesReturnKey = false

    init(
        availability: RemoteWorkspaceAvailability,
        currentDirectory: RemotePath?,
        canGoBack: Bool,
        canGoForward: Bool,
        selectedEntry: RemoteFileEntry?,
        retryDirectoryState: RemoteDirectoryLoadState? = nil
    ) {
        var enabled = Set<RemoteWorkspaceAction>()
        let workspaceIsAvailable = availability == .available

        if workspaceIsAvailable, canGoBack {
            enabled.insert(.goBack)
        }
        if workspaceIsAvailable, canGoForward {
            enabled.insert(.goForward)
        }
        if workspaceIsAvailable, currentDirectory?.parent != nil {
            enabled.insert(.goToParent)
        }
        if workspaceIsAvailable, currentDirectory != nil {
            enabled.insert(.refresh)
        }
        if workspaceIsAvailable, selectedEntry?.kind == .directory {
            enabled.insert(.openSelection)
        }
        if case let .failed(error) = availability,
           Self.isRetryable(error) {
            enabled.insert(.retryWorkspace)
        }
        if workspaceIsAvailable,
           Self.isRetryable(retryDirectoryState) {
            enabled.insert(.retryDirectory)
        }

        if workspaceIsAvailable,
           let target = selectedEntry?.path ?? currentDirectory {
            for action in RemoteWorkspaceAction.copyActions {
                guard let copyAction = action.copyAction,
                      RemotePathCopyText.text(for: copyAction, from: target) != nil else {
                    continue
                }
                enabled.insert(action)
            }
        }

        enabledActions = enabled
    }

    func isEnabled(_ action: RemoteWorkspaceAction) -> Bool {
        enabledActions.contains(action)
    }

    func presentation(
        for action: RemoteWorkspaceAction
    ) -> RemoteWorkspaceActionPresentation {
        let copy = Self.copy(for: action)
        return RemoteWorkspaceActionPresentation(
            title: copy.title,
            help: copy.help,
            accessibilityLabel: copy.accessibilityLabel,
            isEnabled: isEnabled(action)
        )
    }

    private static func isRetryable(_ error: RemoteFileError) -> Bool {
        switch error.category {
        case .transportUnavailable, .malformedResponse, .unsupportedProtocol,
             .unsupportedEntry, .limitExceeded:
            false
        default:
            true
        }
    }

    private static func isRetryable(_ state: RemoteDirectoryLoadState?) -> Bool {
        switch state {
        case let .failed(error, _):
            isRetryable(error)
        case .cancelled:
            true
        default:
            false
        }
    }

    private static func copy(
        for action: RemoteWorkspaceAction
    ) -> (title: String, help: String, accessibilityLabel: String) {
        switch action {
        case .goBack:
            ("Back", "Return to the previous remote directory.", "Back")
        case .goForward:
            ("Forward", "Advance to the next remote directory.", "Forward")
        case .goToParent:
            ("Parent", "Open the parent remote directory.", "Parent directory")
        case .refresh:
            ("Refresh", "Reload this remote directory.", "Refresh remote directory")
        case .openSelection:
            ("Open", "Open the selected remote directory.", "Open selected directory")
        case .retryWorkspace:
            ("Try Again", "Retry loading Remote Workspace.", "Retry Remote Workspace")
        case .retryDirectory:
            ("Retry", "Retry loading this remote directory.", "Retry remote directory")
        case .copyPath:
            ("Copy Path", "Copy the exact remote path as plain text.", "Copy remote path")
        case .copyName:
            ("Copy Name", "Copy the exact remote name as plain text.", "Copy remote name")
        case .copyParentDirectory:
            (
                "Copy Parent Directory",
                "Copy the exact parent remote path as plain text.",
                "Copy parent remote directory"
            )
        case .copyShellQuotedPath:
            (
                "Copy Shell-Quoted Path",
                "Copy a POSIX shell-quoted remote path as plain text.",
                "Copy shell-quoted remote path"
            )
        case .renameSelection:
            (
                "Rename",
                "Rename is unavailable in read-only Remote Workspace.",
                "Rename remote item"
            )
        }
    }
}
