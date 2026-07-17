import SwiftUI
import XMtermRemote

/// One native listing row for a single already-loaded remote entry.
///
/// The row renders safe escaped display text only; entry identity always stays the
/// raw `RemotePath`. It creates no task, performs no provider work, and exposes no
/// open/edit or mutation affordance in read-only Phase 4A.
struct RemoteEntryRow: View {
    static let indentWidth: CGFloat = 14
    static let disclosureSlotWidth: CGFloat = 14

    let entry: RemoteFileEntry
    let depth: Int
    let isExpanded: Bool
    let childState: RemoteDirectoryLoadState?
    let toggleDisclosure: (Bool) -> Void

    var body: some View {
        HStack(spacing: 5) {
            disclosureSlot
            Image(systemName: symbolName)
                .foregroundStyle(symbolColor)
                .accessibilityHidden(true)
            Text(RemoteWorkspacePresentation.displayName(for: entry))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(entry.isHidden ? .secondary : .primary)
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(depth) * Self.indentWidth)
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            RemoteWorkspacePresentation.entryAccessibilityLabel(
                for: entry,
                directoryState: entry.kind == .directory ? childState : nil
            )
        )
    }

    @ViewBuilder
    private var disclosureSlot: some View {
        if entry.kind == .directory {
            Button {
                toggleDisclosure(!isExpanded)
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: Self.disclosureSlotWidth)
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Collapse this remote directory." : "Expand this remote directory.")
            .accessibilityLabel(isExpanded ? "Collapse directory" : "Expand directory")
        } else {
            Color.clear
                .frame(width: Self.disclosureSlotWidth, height: 1)
                .accessibilityHidden(true)
        }
    }

    private var symbolName: String {
        switch entry.kind {
        case .directory: "folder"
        case .regular: "doc.text"
        case .symbolicLink: "link"
        case .other: "questionmark.square.dashed"
        }
    }

    private var symbolColor: AnyShapeStyle {
        switch entry.kind {
        case .directory: AnyShapeStyle(Color.accentColor)
        case .regular, .symbolicLink, .other: AnyShapeStyle(.secondary)
        }
    }

    private var helpText: String {
        let metadata = RemoteWorkspacePresentation.metadata(for: entry)
        var parts = [metadata.kindText]
        if let sizeText = metadata.sizeText {
            parts.append(sizeText)
        }
        if let modificationText = metadata.modificationText {
            parts.append("Modified \(modificationText)")
        }
        if let permissionsText = metadata.permissionsText {
            parts.append("Mode \(permissionsText)")
        }
        if let target = entry.symbolicLinkTarget {
            parts.append("Links to \(target.escapedDisplayString)")
        }
        parts.append(metadata.completenessText)
        return parts.joined(separator: " — ")
    }
}

/// Honest state row rendered beneath an expanded directory whose immediate children
/// are not currently renderable: loading, refreshing, empty, failed, or cancelled.
struct RemoteEntryChildStatusRow: View {
    let state: RemoteDirectoryLoadState
    let depth: Int
    let isRetryEnabled: Bool
    let retry: () -> Void

    var body: some View {
        let status = RemoteWorkspacePresentation.directoryStatus(for: state)
        HStack(spacing: 6) {
            if status.showsProgress {
                ProgressView()
                    .controlSize(.mini)
            }
            Text(status.title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if isRetryEnabled {
                Button("Retry", action: retry)
                    .buttonStyle(.link)
                    .controlSize(.small)
                    .help("Retry loading this remote directory.")
                    .accessibilityLabel("Retry remote directory")
            }
            Spacer(minLength: 0)
        }
        .padding(
            .leading,
            CGFloat(depth) * RemoteEntryRow.indentWidth + RemoteEntryRow.disclosureSlotWidth
        )
        .help(status.detail ?? status.title)
        .accessibilityElement(children: .combine)
    }
}
