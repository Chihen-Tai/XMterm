import Foundation

package struct RemoteTransferExecutionFailure: Error, Sendable {
    package let error: RemoteFileError
    package let manifestBuilder: RemoteTransferManifestBuilder

    package init(
        _ error: Error,
        manifestBuilder: RemoteTransferManifestBuilder
    ) {
        self.error = Self.normalized(error)
        self.manifestBuilder = manifestBuilder
    }

    private static func normalized(_ error: Error) -> RemoteFileError {
        if let execution = error as? Self { return execution.error }
        if let remote = error as? RemoteFileError { return remote }
        if error is CancellationError { return RemoteFileError(category: .cancelled) }
        return RemoteFileError(category: .providerFailure)
    }
}

package enum RemoteTransferItemExecution: Sendable {
    case committed(manifestBuilder: RemoteTransferManifestBuilder, byteCount: UInt64)
    case skipped(manifestBuilder: RemoteTransferManifestBuilder)
    case conflict(RemoteTransferCollision, manifestBuilder: RemoteTransferManifestBuilder)
}

package struct RemoteTransferPlannedItem: Sendable {
    package let requested: RemoteTransferRequestedItem
    package let attempt: RemoteTransferAttemptItem
    package let workKey: RemoteTransferWorkItemKey

    package var presentation: String {
        switch requested.source {
        case let .remote(_, path): path.escapedDisplayString
        case let .local(identity): identity.url.lastPathComponent
        }
    }

    package init(
        requested: RemoteTransferRequestedItem,
        attempt: RemoteTransferAttemptItem
    ) throws {
        self.requested = requested
        self.attempt = attempt
        workKey = try RemoteTransferWorkItemKey(
            topLevelKey: requested.logicalKey,
            relativeRawComponents: []
        )
    }

    package func remoteSource() throws -> (RemoteTransferEndpointSnapshot, RemotePath) {
        guard case let .remote(endpoint, path) = requested.source else {
            throw RemoteFileError(category: .invalidOperation)
        }
        return (endpoint, path)
    }

    package func localSource() throws -> RemoteTransferLocalFileIdentity {
        guard case let .local(identity) = requested.source else {
            throw RemoteFileError(category: .invalidOperation)
        }
        return identity
    }
}
