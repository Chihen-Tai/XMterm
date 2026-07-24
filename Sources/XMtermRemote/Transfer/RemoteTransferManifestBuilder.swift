import Foundation

package struct RemoteTransferManifestBuilder: Sendable {
    private let checkpoints: [RemoteTransferCheckpoint]
    private let cleanupEntries: [RemoteTransferCleanupEntry]

    package init(manifest: RemoteTransferCheckpointManifest) {
        checkpoints = manifest.checkpoints
        cleanupEntries = manifest.cleanupEntries
    }

    private init(
        checkpoints: [RemoteTransferCheckpoint],
        cleanupEntries: [RemoteTransferCleanupEntry]
    ) {
        self.checkpoints = checkpoints
        self.cleanupEntries = cleanupEntries
    }

    package func recordingCleanup(_ entry: RemoteTransferCleanupEntry) throws -> Self {
        let proposed = cleanupEntries + [entry]
        _ = try RemoteTransferCheckpointManifest(
            checkpoints: checkpoints,
            cleanupEntries: proposed
        )
        return Self(checkpoints: checkpoints, cleanupEntries: proposed)
    }

    package func removingCleanup(_ entry: RemoteTransferCleanupEntry) -> Self {
        Self(
            checkpoints: checkpoints,
            cleanupEntries: cleanupEntries.filter { $0 != entry }
        )
    }

    package func checkpointing(
        _ key: RemoteTransferWorkItemKey,
        as disposition: RemoteTransferCheckpointDisposition
    ) throws -> Self {
        let replacement = RemoteTransferCheckpoint(key: key, disposition: disposition)
        let proposed = checkpoints.filter { $0.key != key } + [replacement]
        _ = try RemoteTransferCheckpointManifest(
            checkpoints: proposed,
            cleanupEntries: cleanupEntries
        )
        return Self(checkpoints: proposed, cleanupEntries: cleanupEntries)
    }

    package func build() throws -> RemoteTransferCheckpointManifest {
        try RemoteTransferCheckpointManifest(
            checkpoints: checkpoints,
            cleanupEntries: cleanupEntries
        )
    }
}
