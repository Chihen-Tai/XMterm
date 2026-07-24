import Foundation

package enum RemoteTransferEnginePolicy {
    static func validate(_ request: RemoteTransferRequest) throws {
        guard !request.logicalItemKeys.isEmpty,
              request.logicalItemKeys.count <= RemoteTransferBounds.maximumTopLevelRequestedItemsPerJob,
              Set(request.logicalItemKeys).count == request.logicalItemKeys.count else {
            throw RemoteTransferEngineError.invalidRequest
        }
    }

    static func isRetryable(_ state: RemoteTransferJobState) -> Bool {
        state == .cancelled || state.isFailed
    }

    static func mergedManifest(
        from outcome: RemoteTransferWorkerOutcome,
        request: RemoteTransferRequest,
        attempt: RemoteTransferAttemptIdentity
    ) throws -> RemoteTransferCheckpointManifest {
        let validKeys = Set(request.logicalItemKeys)
        guard outcome.completedItems.isSubset(of: validKeys),
              outcome.checkpointManifest.checkpoints.allSatisfy({
                  validKeys.contains($0.key.topLevelKey)
              }),
              outcome.checkpointManifest.cleanupEntries.allSatisfy({
                  validKeys.contains($0.workItemKey.topLevelKey) && $0.attempt == attempt
              }) else {
            throw RemoteFileError(category: .malformedResponse)
        }

        let keysToCommit: Set<RemoteTransferLogicalItemKey>
        if case .completed = outcome.disposition {
            keysToCommit = validKeys
        } else {
            keysToCommit = outcome.completedItems
        }
        let committedCheckpointKeys: Set<RemoteTransferLogicalItemKey> = Set(
            outcome.checkpointManifest.checkpoints.compactMap { checkpoint in
                guard case .committed = checkpoint.disposition else { return nil }
                return checkpoint.key.topLevelKey
            }
        )
        guard outcome.checkpointManifest.checkpoints.allSatisfy({ checkpoint in
            guard keysToCommit.contains(checkpoint.key.topLevelKey) else { return true }
            if case .committed = checkpoint.disposition { return true }
            return false
        }) else {
            throw RemoteFileError(category: .malformedResponse)
        }
        switch outcome.disposition {
        case let .failed(_, itemFailures):
            let failed = Set(itemFailures.map(\.logicalItemKey))
            guard failed.isDisjoint(with: outcome.completedItems),
                  failed.isDisjoint(with: committedCheckpointKeys) else {
                throw RemoteFileError(category: .malformedResponse)
            }
        case let .conflict(collision):
            guard !outcome.completedItems.contains(collision.logicalItemKey),
                  !committedCheckpointKeys.contains(collision.logicalItemKey) else {
                throw RemoteFileError(category: .malformedResponse)
            }
        case .completed, .cancelled:
            break
        }

        var checkpoints = outcome.checkpointManifest.checkpoints
        var indexByKey = Dictionary(uniqueKeysWithValues: checkpoints.indices.map {
            (checkpoints[$0].key, $0)
        })
        for completed in request.logicalItemKeys where keysToCommit.contains(completed) {
            let key = try RemoteTransferWorkItemKey(
                topLevelKey: completed,
                relativeRawComponents: []
            )
            let checkpoint = RemoteTransferCheckpoint(key: key, disposition: .committed)
            if let index = indexByKey[key] {
                checkpoints[index] = checkpoint
            } else {
                indexByKey[key] = checkpoints.count
                checkpoints.append(checkpoint)
            }
        }
        return try RemoteTransferCheckpointManifest(
            checkpoints: checkpoints,
            cleanupEntries: outcome.checkpointManifest.cleanupEntries
        )
    }

    static func retryableTopLevelKeys(
        request: RemoteTransferRequest,
        manifest: RemoteTransferCheckpointManifest
    ) -> [RemoteTransferLogicalItemKey] {
        let committed = Set(
            manifest.checkpoints.compactMap { checkpoint in
                if case .committed = checkpoint.disposition,
                   checkpoint.key.relativeRawComponents.isEmpty {
                    return checkpoint.key.topLevelKey
                }
                return nil
            }
        )
        return request.logicalItemKeys.filter { !committed.contains($0) }
    }

    static func monotonicTotal<T: FixedWidthInteger>(
        previous: T?,
        proposed: T?,
        completed: T
    ) -> T? {
        guard previous != nil || proposed != nil else { return nil }
        return max(previous ?? 0, proposed ?? 0, completed)
    }

    static func normalized(_ error: Error) -> RemoteFileError {
        if let remoteError = error as? RemoteFileError {
            return remoteError
        }
        return RemoteFileError(category: .providerFailure)
    }

    static func failClosedError(_ error: Error) -> RemoteFileError {
        let category = (error as? RemoteFileError)?.category ?? .providerFailure
        return RemoteFileError(category: category)
    }
}
