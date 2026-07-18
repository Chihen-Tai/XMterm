import Foundation
import Testing
@testable import XMtermRemote

@Suite("Remote file entries and listings")
struct RemoteFileEntryTests {
    @Test("[FILE-META-001, FILE-XFER-004] Stable identity and every entry kind preserve exact paths")
    func stablePathIdentityAndAllKinds() throws {
        let kinds: [RemoteFileEntry.Kind] = [
            .directory,
            .regular,
            .symbolicLink,
            .other
        ]

        for (index, kind) in kinds.enumerated() {
            let path = try remotePath("/workspace/item-\(index)")
            let entry = try RemoteFileEntry(path: path, kind: kind)
            #expect(entry.id == path)
            #expect(entry.path == path)
            #expect(entry.name.losslessString == "item-\(index)")
            #expect(entry.kind == kind)
        }
    }

    @Test("[FILE-LIST-001, FILE-META-001] Partial metadata remains absent instead of being guessed")
    func partialMetadataRemainsExplicit() throws {
        let entry = try RemoteFileEntry(
            path: remotePath("/workspace/unknown"),
            kind: .regular,
            metadataCompleteness: .partial
        )

        #expect(entry.size == nil)
        #expect(entry.modificationDate == nil)
        #expect(entry.permissions == nil)
        #expect(entry.isExecutable == nil)
        #expect(entry.symbolicLinkTarget == nil)
        #expect(entry.metadataCompleteness == .partial)
    }

    @Test("[FILE-LIST-001, FILE-META-001] Hidden and executable behavior derives from raw metadata")
    func hiddenAndExecutableBehavior() throws {
        let executable = try RemoteFileEntry(
            path: remotePath("/workspace/.deploy"),
            kind: .regular,
            size: 42,
            modificationDate: Date(timeIntervalSince1970: 1_234),
            permissions: 0o755,
            metadataCompleteness: .complete
        )
        let ordinary = try RemoteFileEntry(
            path: remotePath("/workspace/readme"),
            kind: .regular,
            permissions: 0o644,
            metadataCompleteness: .complete
        )

        #expect(executable.isHidden)
        #expect(executable.isExecutable == true)
        #expect(executable.size == 42)
        #expect(executable.permissions == 0o755)
        #expect(!ordinary.isHidden)
        #expect(ordinary.isExecutable == false)
    }

    @Test("[FILE-META-001, FILE-XFER-004] Raw symlink targets are bounded and never interpreted")
    func symbolicLinkTargetsPreserveLegalRawBytes() throws {
        let targetBytes = Array("../研究/".utf8) + [0xFF]
        let target = try RemoteSymlinkTarget(rawBytes: targetBytes)
        let entry = try RemoteFileEntry(
            path: remotePath("/workspace/link"),
            kind: .symbolicLink,
            symbolicLinkTarget: target,
            metadataCompleteness: .complete
        )

        #expect(entry.symbolicLinkTarget?.rawBytes == targetBytes)
        #expect(entry.symbolicLinkTarget?.losslessString == nil)
        #expect(entry.symbolicLinkTarget?.escapedDisplayString == "../研究/\\xFF")

        #expect(throws: RemoteFileEntryValidationError.emptySymbolicLinkTarget) {
            try RemoteSymlinkTarget(rawBytes: [])
        }
        #expect(throws: RemoteFileEntryValidationError.symbolicLinkTargetContainsNul) {
            try RemoteSymlinkTarget(rawBytes: [0x61, 0x00])
        }
        #expect(
            throws: RemoteFileEntryValidationError.symbolicLinkTargetTooLong(
                maximum: 32_768,
                actual: 32_769
            )
        ) {
            try RemoteSymlinkTarget(rawBytes: Array(repeating: 0x61, count: 32_769))
        }
        #expect(throws: RemoteFileEntryValidationError.symbolicLinkTargetRequiresSymbolicLinkKind) {
            try RemoteFileEntry(
                path: remotePath("/workspace/not-a-link"),
                kind: .regular,
                symbolicLinkTarget: target
            )
        }
    }

    @Test("[FILE-LIST-001, FILE-XFER-004] Default ordering is kind, raw name bytes, then full raw path")
    func deterministicDefaultOrdering() throws {
        let entries = try [
            RemoteFileEntry(path: remotePath("/root/0-link"), kind: .symbolicLink),
            RemoteFileEntry(path: remotePath("/root/z-directory"), kind: .directory),
            RemoteFileEntry(path: remotePath("/root/b-file"), kind: .regular),
            RemoteFileEntry(path: remotePath("/root/0-other"), kind: .other),
            RemoteFileEntry(path: remotePath("/root/a-file"), kind: .regular),
            RemoteFileEntry(path: rawNamePath(parent: "/root", name: [0xFF]), kind: .regular)
        ]

        let ordered = entries.sorted(by: RemoteFileEntry.defaultOrdering)
        #expect(
            ordered.map(\.kind) == [
                .directory,
                .regular,
                .regular,
                .regular,
                .symbolicLink,
                .other
            ]
        )
        #expect(
            ordered.map { $0.name.rawBytes } == [
                Array("z-directory".utf8),
                Array("a-file".utf8),
                Array("b-file".utf8),
                [0xFF],
                Array("0-link".utf8),
                Array("0-other".utf8)
            ]
        )

        let sameNameDifferentParents = try [
            RemoteFileEntry(path: remotePath("/b/same"), kind: .regular),
            RemoteFileEntry(path: remotePath("/a/same"), kind: .regular)
        ].sorted(by: RemoteFileEntry.defaultOrdering)
        #expect(sameNameDifferentParents.map(\.path.losslessString) == ["/a/same", "/b/same"])
    }

    @Test("[FILE-CACHE-001, FILE-LIST-001] Listings are sorted immutable immediate-child snapshots")
    func listingIsSortedBoundedAndImmutable() throws {
        let directory = try remotePath("/workspace")
        let directoryEntry = try RemoteFileEntry(
            path: remotePath("/workspace/z-directory"),
            kind: .directory
        )
        let fileEntry = try RemoteFileEntry(
            path: remotePath("/workspace/a-file"),
            kind: .regular
        )
        var input = [fileEntry, directoryEntry]
        let listing = try RemoteDirectoryListing(
            directory: directory,
            entries: input,
            metadataCompleteness: .partial,
            providerCapabilityNotes: "Mode details unavailable"
        )

        input.removeAll()
        var exposedEntries = listing.entries
        exposedEntries.removeLast()

        #expect(listing.directory == directory)
        #expect(listing.entries.map(\.path) == [directoryEntry.path, fileEntry.path])
        #expect(listing.entries.count == 2)
        #expect(listing.metadataCompleteness == .partial)
        #expect(listing.providerCapabilityNotes == "Mode details unavailable")
    }

    @Test("[FILE-CACHE-001, FILE-LIST-001] Listings reject untrusted structure and configured limits")
    func listingValidationRejectsInvalidStructureAndLimits() throws {
        let directory = try remotePath("/workspace")
        let child = try RemoteFileEntry(
            path: remotePath("/workspace/item"),
            kind: .regular
        )
        let outside = try RemoteFileEntry(path: remotePath("/other/item"), kind: .regular)

        #expect(throws: RemoteDirectoryListingValidationError.entryOutsideDirectory(outside.path)) {
            try RemoteDirectoryListing(directory: directory, entries: [outside])
        }
        #expect(throws: RemoteDirectoryListingValidationError.duplicateEntry(child.path)) {
            try RemoteDirectoryListing(directory: directory, entries: [child, child])
        }
        #expect(
            throws: RemoteDirectoryListingValidationError.tooManyEntries(
                maximum: 10_000,
                actual: 10_001
            )
        ) {
            try RemoteDirectoryListing(
                directory: directory,
                entries: Array(repeating: child, count: 10_001)
            )
        }
        #expect(
            throws: RemoteDirectoryListingValidationError.capabilityNotesTooLong(
                maximum: 65_536,
                actual: 65_537
            )
        ) {
            try RemoteDirectoryListing(
                directory: directory,
                entries: [child],
                providerCapabilityNotes: String(repeating: "x", count: 65_537)
            )
        }
    }

    @Test("[FILE-STATE-001] Remote failures retain typed categories and bounded safe user copy")
    func remoteErrorsAreTypedAndBounded() {
        #expect(
            RemoteFileError.Category.allCases == [
                .authenticationRequired,
                .hostKeyVerificationFailed,
                .interactiveAuthenticationUnsupported,
                .permissionDenied,
                .pathNotFound,
                .notDirectory,
                .alreadyExists,
                .directoryNotEmpty,
                .invalidOperation,
                .disconnected,
                .connectionRefused,
                .timeout,
                .cancelled,
                .malformedResponse,
                .unsupportedProtocol,
                .unsupportedEntry,
                .limitExceeded,
                .transportUnavailable,
                .providerFailure,
                .unknown
            ]
        )

        let source = String(repeating: "🚀", count: 20_000) + "\n\u{0}"
        let error = RemoteFileError(
            category: .providerFailure,
            userFacingMessage: source
        )
        #expect(error.category == .providerFailure)
        #expect(
            error.userFacingMessage.utf8.count
                <= RemoteFileError.maximumUserFacingMessageByteCount
        )
        #expect(!error.userFacingMessage.contains("\n"))
        #expect(!error.userFacingMessage.contains("\u{0}"))
        #expect(!RemoteFileError(category: .timeout).userFacingMessage.isEmpty)
    }

    @Test("[FILE-COPY-001, FILE-STATE-001, FILE-XFER-004] Unsafe Unicode uses one safe display policy")
    func unsafeUnicodeUsesOneSafeDisplayPolicy() throws {
        let unsafeText = "prefix\u{202E}name\u{2066}visible\u{2069}"
        let expected = "prefix\\u{202E}name\\u{2066}visible\\u{2069}"
        let target = try RemoteSymlinkTarget(rawBytes: Array(unsafeText.utf8))
        let child = try RemoteFileEntry(
            path: remotePath("/workspace/item"),
            kind: .symbolicLink,
            symbolicLinkTarget: target
        )
        let listing = try RemoteDirectoryListing(
            directory: remotePath("/workspace"),
            entries: [child],
            providerCapabilityNotes: unsafeText
        )
        let error = RemoteFileError(
            category: .providerFailure,
            userFacingMessage: unsafeText
        )

        #expect(target.rawBytes == Array(unsafeText.utf8))
        #expect(target.losslessString == unsafeText)
        #expect(target.escapedDisplayString == expected)
        #expect(listing.providerCapabilityNotes == expected)
        #expect(error.userFacingMessage == expected)

        let ordinaryText = "研究 e\u{301} 👨‍👩‍👧‍👦"
        #expect(
            RemoteFileError(
                category: .unknown,
                userFacingMessage: ordinaryText
            ).userFacingMessage == ordinaryText
        )
        #expect(
            RemoteFileError(
                category: .unknown,
                userFacingMessage: "a\u{200D}b"
            ).userFacingMessage == "a\\u{200D}b"
        )
    }

    @Test("[FILE-META-001] Entry construction rejects roots, invalid permission bits, and mismatched links")
    func entryConstructionValidatesMetadata() throws {
        #expect(throws: RemoteFileEntryValidationError.rootCannotBeEntry) {
            try RemoteFileEntry(path: .root, kind: .directory)
        }
        #expect(throws: RemoteFileEntryValidationError.invalidPermissionBits(0o10_000)) {
            try RemoteFileEntry(
                path: remotePath("/workspace/item"),
                kind: .regular,
                permissions: 0o10_000
            )
        }
    }

    private func remotePath(_ value: String) throws -> RemotePath {
        try RemotePath(rawBytes: Array(value.utf8))
    }

    private func rawNamePath(parent: String, name: [UInt8]) throws -> RemotePath {
        let parentPath = try remotePath(parent)
        return try parentPath.appending(RemotePathComponent(rawBytes: name))
    }
}
