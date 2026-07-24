import Foundation

package enum RemoteTransferPublicationChoice: Sendable {
    case newDestination
    case atomicReplace
    case nonAtomicFallback
    case skip
    case conflict(RemoteTransferCollision)
    case cancel
}

package enum RemoteTransferPublicationPolicy {
    package static func choice(
        context: RemoteTransferWorkerContext,
        item: RemoteTransferPlannedItem,
        destination: RemotePath,
        provider: any RemoteTransferEndpointProvider
    ) async throws -> RemoteTransferPublicationChoice {
        guard try await exists(destination, provider: provider) else {
            return .newDestination
        }
        let collision = RemoteTransferCollision(
            workItemKey: item.workKey,
            destination: destination
        )
        var resolution = context.resolvedCollision?.resolution(ifRevalidated: collision)
            ?? context.applyToAllResolution.flatMap { $0.applyToAll ? $0 : nil }
        if resolution == nil {
            resolution = try policyResolution(context.request.collisionPolicy)
        }
        guard let resolution else { return .conflict(collision) }

        switch resolution.decision {
        case .skip:
            return .skip
        case .keepBoth:
            return .conflict(collision)
        case .cancel:
            return .cancel
        case .replace:
            let capabilities = await provider.capabilities
            if capabilities.supportsAtomicReplace {
                return .atomicReplace
            }
            guard resolution.replacementGuarantee
                    == .explicitlyAcceptedNonAtomicFallback else {
                return .conflict(collision)
            }
            return .nonAtomicFallback
        }
    }

    package static func publish(
        staging: RemotePath,
        destination: RemotePath,
        endpoint: RemoteTransferEndpointSnapshot,
        item: RemoteTransferPlannedItem,
        context: RemoteTransferWorkerContext,
        choice: RemoteTransferPublicationChoice,
        provider: any RemoteTransferEndpointProvider,
        manifestBuilder: RemoteTransferManifestBuilder
    ) async throws -> RemoteTransferManifestBuilder {
        switch choice {
        case .newDestination:
            try await provider.rename(staging, to: destination, replace: false)
            return manifestBuilder.removingCleanup(
                remoteCleanup(
                    path: staging,
                    endpoint: endpoint,
                    item: item,
                    attempt: context.attempt
                )
            )
        case .atomicReplace:
            try await provider.rename(staging, to: destination, replace: true)
            return manifestBuilder.removingCleanup(
                remoteCleanup(
                    path: staging,
                    endpoint: endpoint,
                    item: item,
                    attempt: context.attempt
                )
            )
        case .nonAtomicFallback:
            let task = Task.detached {
                try await fallbackPublish(
                    staging: staging,
                    destination: destination,
                    endpoint: endpoint,
                    item: item,
                    context: context,
                    provider: provider,
                    manifestBuilder: manifestBuilder
                )
            }
            return try await task.value
        case .skip, .conflict, .cancel:
            throw RemoteFileError(category: .invalidOperation)
        }
    }

    private static func fallbackPublish(
        staging: RemotePath,
        destination: RemotePath,
        endpoint: RemoteTransferEndpointSnapshot,
        item: RemoteTransferPlannedItem,
        context: RemoteTransferWorkerContext,
        provider: any RemoteTransferEndpointProvider,
        manifestBuilder: RemoteTransferManifestBuilder
    ) async throws -> RemoteTransferManifestBuilder {
        guard let parent = destination.parent else {
            throw RemoteTransferExecutionFailure(
                RemoteFileError(category: .invalidOperation),
                manifestBuilder: manifestBuilder
            )
        }
        let backup = try parent.appending(
            try component(
                prefix: ".xmterm-backup-",
                attempt: context.attempt,
                itemID: item.attempt.attemptItemID
            )
        )
        if try await exists(backup, provider: provider) {
            throw RemoteTransferExecutionFailure(
                RemoteFileError(category: .alreadyExists),
                manifestBuilder: manifestBuilder
            )
        }
        let backupCleanup = remoteCleanup(
            path: backup,
            endpoint: endpoint,
            item: item,
            attempt: context.attempt
        )
        var builder = try manifestBuilder.recordingCleanup(backupCleanup)
        do {
            try await provider.rename(destination, to: backup, replace: false)
        } catch {
            throw RemoteTransferExecutionFailure(error, manifestBuilder: builder)
        }

        do {
            try await provider.rename(staging, to: destination, replace: false)
            builder = builder.removingCleanup(
                remoteCleanup(
                    path: staging,
                    endpoint: endpoint,
                    item: item,
                    attempt: context.attempt
                )
            )
        } catch let finalizeError {
            do {
                try await provider.rename(backup, to: destination, replace: false)
                builder = builder.removingCleanup(backupCleanup)
            } catch let restoreError {
                throw RemoteTransferExecutionFailure(
                    restoreError,
                    manifestBuilder: builder
                )
            }
            throw RemoteTransferExecutionFailure(
                finalizeError,
                manifestBuilder: builder
            )
        }

        do {
            try await provider.removeFile(backup)
            return builder.removingCleanup(backupCleanup)
        } catch {
            throw RemoteTransferExecutionFailure(error, manifestBuilder: builder)
        }
    }

    package static func stagingPath(
        parent: RemotePath,
        context: RemoteTransferWorkerContext,
        item: RemoteTransferPlannedItem
    ) throws -> RemotePath {
        try parent.appending(
            try component(
                prefix: ".xmterm-partial-",
                attempt: context.attempt,
                itemID: item.attempt.attemptItemID
            )
        )
    }

    package static func remoteCleanup(
        path: RemotePath,
        endpoint: RemoteTransferEndpointSnapshot,
        item: RemoteTransferPlannedItem,
        attempt: RemoteTransferAttemptIdentity
    ) -> RemoteTransferCleanupEntry {
        RemoteTransferCleanupEntry(
            attempt: attempt,
            workItemKey: item.workKey,
            location: .remote(endpointID: endpoint.id, path: path)
        )
    }

    private static func exists(
        _ path: RemotePath,
        provider: any RemoteTransferEndpointProvider
    ) async throws -> Bool {
        do {
            _ = try await provider.lstat(path)
            return true
        } catch let error as RemoteFileError where error.category == .pathNotFound {
            return false
        }
    }

    private static func policyResolution(
        _ policy: RemoteTransferCollisionPolicy
    ) throws -> RemoteTransferCollisionResolution? {
        let decision: RemoteTransferCollisionDecision
        switch policy {
        case .replace: decision = .replace
        case .skip: decision = .skip
        case .keepBoth: decision = .keepBoth
        case .ask, .notApplicable: return nil
        }
        return try RemoteTransferCollisionResolution(
            decision: decision,
            applyToAll: false
        )
    }

    private static func component(
        prefix: String,
        attempt: RemoteTransferAttemptIdentity,
        itemID: RemoteTransferAttemptItemID
    ) throws -> RemotePathComponent {
        do {
            return try RemotePathComponent(
                rawBytes: Array(
                    "\(prefix)\(attempt.id.uuidString)-\(itemID.rawValue.uuidString)".utf8
                )
            )
        } catch {
            throw RemoteFileError(category: .invalidOperation)
        }
    }
}
