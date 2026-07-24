import Foundation

package struct RemoteTransferProductionWorker: RemoteTransferWorker {
    private let context: RemoteTransferWorkerContext
    private let resolver: RemoteTransferEndpointProviderResolver
    private let localStaging: any LocalTransferStaging
    private let plannedItems: [PlannedItem]

    package init(
        context: RemoteTransferWorkerContext,
        resolver: RemoteTransferEndpointProviderResolver,
        localStaging: any LocalTransferStaging
    ) throws {
        self.context = context
        self.resolver = resolver
        self.localStaging = localStaging
        plannedItems = try Self.planItems(context)
    }

    package func run(
        report: @escaping @Sendable (RemoteTransferWorkerEvent) async -> Void
    ) async -> RemoteTransferWorkerOutcome {
        var builder = RemoteTransferManifestBuilder(manifest: context.checkpointManifest)
        var completed = Set(context.excludedCompletedItems)
        let session: RemoteTransferEndpointSession
        do {
            try Task.checkCancellation()
            session = try await resolver.acquire(for: context.request)
        } catch {
            return failedOutcome(error, builder: builder, completed: completed)
        }

        do {
            await report(.phase(.transferring))
            for (index, item) in plannedItems.enumerated() {
                try Task.checkCancellation()
                await report(
                    .currentItem(
                        RemoteTransferPresentationText(bounding: item.presentation)
                    )
                )
                try await execute(item, session: session)
                builder = try builder.checkpointing(item.workKey, as: .committed)
                completed.insert(item.requested.logicalKey)
                await report(
                    .progress(
                        bytesCompleted: 0,
                        bytesTotal: nil,
                        itemsCompleted: index + 1,
                        itemsTotal: plannedItems.count
                    )
                )
            }
            await report(.phase(.verifying))
            await session.settle()
            return .completed(
                completedItems: completed,
                checkpointManifest: try builder.build()
            )
        } catch {
            await session.settle()
            if error is CancellationError || Task.isCancelled {
                return cancelledOutcome(builder: builder, completed: completed)
            }
            return failedOutcome(error, builder: builder, completed: completed)
        }
    }

    private func execute(
        _ item: PlannedItem,
        session: RemoteTransferEndpointSession
    ) async throws {
        switch context.request.kind {
        case .createFile:
            let (endpoint, path) = try item.remoteSource()
            try await session.provider(for: endpoint).createFile(path)
        default:
            throw RemoteFileError(category: .invalidOperation)
        }
    }

    private func failedOutcome(
        _ error: Error,
        builder: RemoteTransferManifestBuilder,
        completed: Set<RemoteTransferLogicalItemKey>
    ) -> RemoteTransferWorkerOutcome {
        var normalized = Self.normalized(error)
        let failedItem = plannedItems.first { !completed.contains($0.requested.logicalKey) }
        let manifest: RemoteTransferCheckpointManifest
        do {
            let failedBuilder: RemoteTransferManifestBuilder
            if let failedItem {
                failedBuilder = try builder.checkpointing(
                    failedItem.workKey,
                    as: .failed(normalized)
                )
            } else {
                failedBuilder = builder
            }
            manifest = try failedBuilder.build()
        } catch {
            normalized = Self.normalized(error)
            manifest = context.checkpointManifest
        }
        let failures: [RemoteTransferItemFailure]
        if let failedItem {
            failures = [
                RemoteTransferItemFailure(
                    logicalItemKey: failedItem.requested.logicalKey,
                    error: normalized
                )
            ]
        } else {
            failures = []
        }
        return .failed(
            error: normalized,
            itemFailures: failures,
            completedItems: completed,
            checkpointManifest: manifest
        )
    }

    private func cancelledOutcome(
        builder: RemoteTransferManifestBuilder,
        completed: Set<RemoteTransferLogicalItemKey>
    ) -> RemoteTransferWorkerOutcome {
        do {
            return .cancelled(
                completedItems: completed,
                checkpointManifest: try builder.build()
            )
        } catch {
            return failedOutcome(error, builder: builder, completed: completed)
        }
    }

    private static func normalized(_ error: Error) -> RemoteFileError {
        if let remoteError = error as? RemoteFileError { return remoteError }
        if error is CancellationError { return RemoteFileError(category: .cancelled) }
        return RemoteFileError(category: .providerFailure)
    }

    private static func planItems(_ context: RemoteTransferWorkerContext) throws -> [PlannedItem] {
        var attempts: [RemoteTransferLogicalItemKey: RemoteTransferAttemptItem] = [:]
        for item in context.items {
            guard attempts[item.logicalItemKey] == nil else {
                throw RemoteFileError(category: .invalidOperation)
            }
            attempts[item.logicalItemKey] = item
        }
        guard attempts.count == context.items.count,
              Set(attempts.keys) == Set(context.request.logicalItemKeys) else {
            throw RemoteFileError(category: .invalidOperation)
        }
        return try context.request.requestedItems.compactMap { requested in
            guard !context.excludedCompletedItems.contains(requested.logicalKey) else {
                return nil
            }
            guard let attempt = attempts[requested.logicalKey] else {
                throw RemoteFileError(category: .invalidOperation)
            }
            return try PlannedItem(requested: requested, attempt: attempt)
        }
    }
}

private struct PlannedItem: Sendable {
    let requested: RemoteTransferRequestedItem
    let attempt: RemoteTransferAttemptItem
    let workKey: RemoteTransferWorkItemKey

    var presentation: String {
        switch requested.source {
        case let .remote(_, path): path.escapedDisplayString
        case let .local(identity): identity.url.lastPathComponent
        }
    }

    init(
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

    func remoteSource() throws -> (RemoteTransferEndpointSnapshot, RemotePath) {
        guard case let .remote(endpoint, path) = requested.source else {
            throw RemoteFileError(category: .invalidOperation)
        }
        return (endpoint, path)
    }
}
