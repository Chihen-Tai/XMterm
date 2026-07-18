import Foundation
import Testing
import XMtermRemote
@testable import XMtermApp

@Suite("Remote workspace presentation")
struct RemoteWorkspacePresentationTests {
    @Test("[FILE-WORKSPACE-001, FILE-STATE-001] local sessions explain why no tree exists")
    func localSessionExplanationIsExplicit() {
        #expect(
            RemoteWorkspacePresentation.localSessionExplanation
                == "Remote Workspace is available for SSH sessions"
        )
    }

    @Test("[FILE-STATE-001] workspace lifecycle labels remain distinct and honest")
    func workspaceLifecycleLabelsAreDistinct() {
        let idle = RemoteWorkspacePresentation.workspaceStatus(for: .idle)
        let connecting = RemoteWorkspacePresentation.workspaceStatus(for: .connecting)
        let loading = RemoteWorkspacePresentation.workspaceStatus(for: .loadingInitialDirectory)
        let available = RemoteWorkspacePresentation.workspaceStatus(for: .available)
        let closing = RemoteWorkspacePresentation.workspaceStatus(for: .closing)
        let closed = RemoteWorkspacePresentation.workspaceStatus(for: .closed)

        #expect(idle.title == "Remote Workspace idle")
        #expect(connecting.title == "Connecting to Remote Workspace…")
        #expect(connecting.showsProgress)
        #expect(loading.title == "Loading initial remote directory…")
        #expect(loading.showsProgress)
        #expect(available.title == "Remote Workspace ready")
        #expect(!available.showsProgress)
        #expect(closing.title == "Closing Remote Workspace…")
        #expect(closed.title == "Remote Workspace closed")
    }

    @Test("[FILE-STATE-001] transport blockage is not presented as an empty directory")
    func transportUnavailableIsExplicit() {
        let error = RemoteFileError(
            category: .transportUnavailable,
            userFacingMessage: "Structured SFTP transport is not installed."
        )

        let status = RemoteWorkspacePresentation.workspaceStatus(for: .failed(error))

        #expect(status.title == "Remote file transport unavailable")
        #expect(status.detail == "Structured SFTP transport is not installed.")
        #expect(!status.showsProgress)
        #expect(!status.title.localizedCaseInsensitiveContains("empty"))
    }

    @Test("[FILE-STATE-001] ordinary workspace failures preserve bounded provider detail")
    func ordinaryFailureUsesTypedDetail() {
        let error = RemoteFileError(
            category: .permissionDenied,
            userFacingMessage: "Permission denied for this directory."
        )

        let status = RemoteWorkspacePresentation.workspaceStatus(for: .failed(error))

        #expect(status.title == "Remote Workspace unavailable")
        #expect(status.detail == error.userFacingMessage)
    }

    @Test("[FILE-STATE-001] directory loading refreshing empty failure and cancellation differ")
    func directoryStateLabelsAreDistinct() throws {
        let directory = try RemotePath(rawBytes: Array("/work".utf8))
        let prior = try RemoteDirectoryListing(directory: directory, entries: [])
        let failure = RemoteFileError(category: .timeout)

        #expect(
            RemoteWorkspacePresentation.directoryStatus(for: .notLoaded).title
                == "Not loaded"
        )
        #expect(
            RemoteWorkspacePresentation.directoryStatus(
                for: .loading(previousListing: nil)
            ).title == "Loading directory…"
        )
        #expect(
            RemoteWorkspacePresentation.directoryStatus(
                for: .loading(previousListing: prior)
            ).title == "Refreshing directory…"
        )
        #expect(
            RemoteWorkspacePresentation.directoryStatus(for: .empty(prior)).title
                == "This directory is empty"
        )
        let failed = RemoteWorkspacePresentation.directoryStatus(
            for: .failed(error: failure, previousListing: prior)
        )
        #expect(failed.title == "Couldn’t load this directory")
        #expect(failed.detail == failure.userFacingMessage)
        #expect(
            RemoteWorkspacePresentation.directoryStatus(
                for: .cancelled(previousListing: prior)
            ).title == "Directory loading cancelled"
        )
    }

    @Test("[FILE-LIST-001, FILE-META-001] present metadata is exact and absent metadata stays absent")
    func metadataDoesNotGuess() throws {
        let partial = try entry(path: "/work/note.txt", kind: .regular)
        let complete = try entry(
            path: "/work/tool",
            kind: .regular,
            size: 42,
            modificationDate: Date(timeIntervalSince1970: 0),
            permissions: 0o755,
            completeness: .complete
        )

        let partialPresentation = RemoteWorkspacePresentation.metadata(for: partial)
        let completePresentation = RemoteWorkspacePresentation.metadata(for: complete)

        #expect(partialPresentation.sizeText == nil)
        #expect(partialPresentation.modificationText == nil)
        #expect(partialPresentation.permissionsText == nil)
        #expect(partialPresentation.completenessText == "Metadata incomplete")
        #expect(completePresentation.sizeText == "42 bytes")
        #expect(completePresentation.modificationText == "1970-01-01 00:00:00 UTC")
        #expect(completePresentation.permissionsText == "0755")
        #expect(completePresentation.completenessText == "Metadata complete")
    }

    @Test("[FILE-LIST-001, A11Y-001] entry labels include safe name kind and directory state")
    func accessibilityUsesSafeDisplayText() throws {
        let path = try RemotePath(rawBytes: [0x2F, 0x77, 0x6F, 0x72, 0x6B, 0x2F, 0x66, 0x80])
        let entry = try RemoteFileEntry(path: path, kind: .directory)

        let displayName = RemoteWorkspacePresentation.displayName(for: entry)
        let label = RemoteWorkspacePresentation.entryAccessibilityLabel(
            for: entry,
            directoryState: .loading(previousListing: nil)
        )

        #expect(displayName == "f\\x80")
        #expect(label == "f\\x80, Folder, Loading directory…")
        #expect(!label.contains("\n"))
        #expect(!label.contains("\r"))
    }

    @Test("[FILE-NAV-002, A11Y-001] breadcrumbs announce the structured destination")
    func breadcrumbAccessibilityNamesDestination() throws {
        let path = try RemotePath(rawBytes: Array("/研究/notes".utf8))

        #expect(
            RemoteWorkspacePresentation.breadcrumbAccessibilityLabel(for: .root)
                == "Remote directory /"
        )
        #expect(
            RemoteWorkspacePresentation.breadcrumbAccessibilityLabel(for: path)
                == "Remote directory /研究/notes"
        )
    }

    @Test("[FILE-STATE-001] only the trusted simulated provider mode produces the SIMULATED badge")
    func simulatedBadgeComesOnlyFromTrustedProviderMode() {
        #expect(RemoteWorkspacePresentation.simulatedBadge(for: .production) == nil)
        #expect(RemoteWorkspacePresentation.simulatedBadge(for: .unavailable) == nil)
        #expect(RemoteWorkspacePresentation.simulatedBadge(for: .packageTest) == nil)

        let badge = RemoteWorkspacePresentation.simulatedBadge(
            for: .simulatedDeveloperFixture
        )
        #expect(badge?.title == "SIMULATED")
        #expect(badge?.detail == "Developer fixture — not a real remote host")
        #expect(badge?.accessibilityLabel.contains("Simulated") == true)
        #expect(badge?.accessibilityLabel.contains("not a real remote host") == true)
    }

    private func entry(
        path: String,
        kind: RemoteFileEntry.Kind,
        size: UInt64? = nil,
        modificationDate: Date? = nil,
        permissions: UInt16? = nil,
        completeness: RemoteMetadataCompleteness = .partial
    ) throws -> RemoteFileEntry {
        try RemoteFileEntry(
            path: RemotePath(rawBytes: Array(path.utf8)),
            kind: kind,
            size: size,
            modificationDate: modificationDate,
            permissions: permissions,
            metadataCompleteness: completeness
        )
    }
}
