public enum RemoteDirectoryListingValidationError: Error, Equatable, Sendable {
    case tooManyEntries(maximum: Int, actual: Int)
    case entryOutsideDirectory(RemotePath)
    case duplicateEntry(RemotePath)
    case capabilityNotesTooLong(maximum: Int, actual: Int)
}

public struct RemoteDirectoryListing: Equatable, Sendable {
    public static let maximumEntryCount = 10_000
    public static let maximumCapabilityNotesByteCount = 64 * 1_024

    public let directory: RemotePath
    public let metadataCompleteness: RemoteMetadataCompleteness
    public let providerCapabilityNotes: String?

    private let storedEntries: [RemoteFileEntry]

    public var entries: [RemoteFileEntry] {
        storedEntries
    }

    public init(
        directory: RemotePath,
        entries: [RemoteFileEntry],
        metadataCompleteness: RemoteMetadataCompleteness = .partial,
        providerCapabilityNotes: String? = nil
    ) throws {
        guard entries.count <= Self.maximumEntryCount else {
            throw RemoteDirectoryListingValidationError.tooManyEntries(
                maximum: Self.maximumEntryCount,
                actual: entries.count
            )
        }
        if let providerCapabilityNotes {
            let byteCount = providerCapabilityNotes.utf8.count
            guard byteCount <= Self.maximumCapabilityNotesByteCount else {
                throw RemoteDirectoryListingValidationError.capabilityNotesTooLong(
                    maximum: Self.maximumCapabilityNotesByteCount,
                    actual: byteCount
                )
            }
        }
        try Self.validateEntries(entries, belongTo: directory)

        self.directory = directory
        storedEntries = entries.sorted(by: RemoteFileEntry.defaultOrdering)
        self.metadataCompleteness = metadataCompleteness
        self.providerCapabilityNotes = providerCapabilityNotes.map {
            RemoteUserFacingText.bounded(
                $0,
                maximumByteCount: Self.maximumCapabilityNotesByteCount
            )
        }
    }

    private static func validateEntries(
        _ entries: [RemoteFileEntry],
        belongTo directory: RemotePath
    ) throws {
        var seenPaths = Set<RemotePath>()
        for entry in entries {
            guard entry.path.parent == directory else {
                throw RemoteDirectoryListingValidationError.entryOutsideDirectory(entry.path)
            }
            guard seenPaths.insert(entry.path).inserted else {
                throw RemoteDirectoryListingValidationError.duplicateEntry(entry.path)
            }
        }
    }
}
