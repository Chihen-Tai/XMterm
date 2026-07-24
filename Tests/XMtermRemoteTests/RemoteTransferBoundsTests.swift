import Foundation
import Testing
import XMtermCore

@testable import XMtermRemote

@Suite("Remote transfer exact bounds")
struct RemoteTransferBoundsTests {
    @Test("[APP-008] presentation text accepts exactly 4 KiB and rejects boundary plus one")
    func presentationTextBoundIsExact() throws {
        let valid = String(repeating: "a", count: RemoteTransferPresentationText.maximumUTF8ByteCount)
        #expect(try RemoteTransferPresentationText(valid).value == valid)

        let invalid = valid + "b"
        #expect(throws: RemoteFileError(category: .limitExceeded)) {
            try RemoteTransferPresentationText(invalid)
        }
    }

    @Test("[FILE-XFER-001] request item bound is exact")
    func requestItemBoundIsExact() throws {
        let owner = transferOwner("11111111-1111-1111-1111-111111111111")
        let endpoint = try makeEndpoint(owner: owner, id: "22222222-2222-2222-2222-222222222222")
        _ = try uploadRequest(itemCount: RemoteTransferBounds.maximumTopLevelRequestedItemsPerJob, owner: owner, endpoint: endpoint)

        #expect(throws: RemoteFileError(category: .limitExceeded)) {
            try uploadRequest(
                itemCount: RemoteTransferBounds.maximumTopLevelRequestedItemsPerJob + 1,
                owner: owner,
                endpoint: endpoint
            )
        }
    }

    @Test("[FILE-XFER-001, MAC-006] local identity byte budgets are exact")
    func localIdentityByteBudgetsAreExact() throws {
        _ = try RemoteTransferLocalFileIdentity(
            url: URL(fileURLWithPath: "/" + String(repeating: "u", count: 32 * 1_024 - 1)),
            fileResourceIdentifier: Data(repeating: 1, count: 4 * 1_024),
            volumeIdentifier: Data(repeating: 2, count: 4 * 1_024),
            kind: .regularFile,
            observedSize: nil,
            observedModificationNanoseconds: nil,
            securityScopedBookmark: Data(repeating: 3, count: 64 * 1_024)
        )

        #expect(throws: RemoteFileError(category: .limitExceeded)) {
            try RemoteTransferLocalFileIdentity(
                url: URL(fileURLWithPath: "/" + String(repeating: "u", count: 32 * 1_024)),
                fileResourceIdentifier: Data([1]),
                volumeIdentifier: nil,
                kind: .regularFile,
                observedSize: nil,
                observedModificationNanoseconds: nil,
                securityScopedBookmark: nil
            )
        }
        #expect(throws: RemoteFileError(category: .limitExceeded)) {
            try RemoteTransferLocalFileIdentity(
                url: URL(fileURLWithPath: "/tmp/file"),
                fileResourceIdentifier: Data(repeating: 1, count: 4 * 1_024 + 1),
                volumeIdentifier: nil,
                kind: .regularFile,
                observedSize: nil,
                observedModificationNanoseconds: nil,
                securityScopedBookmark: nil
            )
        }
        #expect(throws: RemoteFileError(category: .limitExceeded)) {
            try RemoteTransferLocalFileIdentity(
                url: URL(fileURLWithPath: "/tmp/file"),
                fileResourceIdentifier: Data([1]),
                volumeIdentifier: Data(repeating: 2, count: 4 * 1_024 + 1),
                kind: .regularFile,
                observedSize: nil,
                observedModificationNanoseconds: nil,
                securityScopedBookmark: nil
            )
        }
        #expect(throws: RemoteFileError(category: .limitExceeded)) {
            try RemoteTransferLocalFileIdentity(
                url: URL(fileURLWithPath: "/tmp/file"),
                fileResourceIdentifier: Data([1]),
                volumeIdentifier: nil,
                kind: .regularFile,
                observedSize: nil,
                observedModificationNanoseconds: nil,
                securityScopedBookmark: Data(repeating: 3, count: 64 * 1_024 + 1)
            )
        }
    }

    @Test("[FILE-XFER-001, MAC-006] local identity requires absolute file URL and nonempty file ID")
    func localIdentityRequiresAbsoluteFileURLAndNonemptyFileID() {
        #expect(throws: RemoteFileError(category: .invalidOperation)) {
            try RemoteTransferLocalFileIdentity(
                url: URL(string: "relative/path")!,
                fileResourceIdentifier: Data([1]),
                volumeIdentifier: nil,
                kind: .regularFile,
                observedSize: nil,
                observedModificationNanoseconds: nil,
                securityScopedBookmark: nil
            )
        }
        #expect(throws: RemoteFileError(category: .invalidOperation)) {
            try RemoteTransferLocalFileIdentity(
                url: URL(fileURLWithPath: "/tmp/file"),
                fileResourceIdentifier: Data(),
                volumeIdentifier: nil,
                kind: .regularFile,
                observedSize: nil,
                observedModificationNanoseconds: nil,
                securityScopedBookmark: nil
            )
        }
    }

    @Test("[FILE-XFER-001, MAC-006] endpoint retained bytes are checked and capped")
    func endpointRetainedBytesAreCheckedAndCapped() throws {
        let owner = transferOwner("11111111-1111-1111-1111-111111111111")
        _ = try makeEndpoint(
            owner: owner,
            id: "22222222-2222-2222-2222-222222222222",
            retainedByteCount: RemoteTransferBounds.maximumJobRetainedByteCount - "Relay".utf8.count
        )

        #expect(throws: RemoteFileError(category: .limitExceeded)) {
            try makeEndpoint(
                owner: owner,
                id: "33333333-3333-3333-3333-333333333333",
                retainedByteCount: RemoteTransferBounds.maximumJobRetainedByteCount
            )
        }
        #expect(throws: RemoteFileError(category: .limitExceeded)) {
            try makeEndpoint(
                owner: owner,
                id: "44444444-4444-4444-4444-444444444444",
                retainedByteCount: Int.max
            )
        }
    }

    @Test("[APP-008] same-endpoint copy charges endpoint material once at the exact request bound")
    func sameEndpointCopyChargesEndpointOnceAtExactBound() throws {
        let owner = transferOwner("11111111-1111-1111-1111-111111111111")
        let sourcePath = try remotePath("/source-copy")
        let destinationPath = try remotePath("/destination-copy")
        let endpoint = try endpointFillingRequestBound(
            owner: owner,
            id: "22222222-2222-2222-2222-222222222222",
            pathByteCount: sourcePath.rawBytes.count + destinationPath.rawBytes.count
        )

        let request = try RemoteTransferRequest(
            id: UUID(),
            owner: owner,
            kind: .remoteCopy,
            requestedItems: [
                .init(logicalKey: .init(), source: .remote(endpoint: endpoint, path: sourcePath))
            ],
            destination: .remoteDirectory(endpoint: endpoint, path: destinationPath),
            collisionPolicy: .ask,
            metadataPolicy: .preserveSupportedPermissions,
            symlinkPolicy: .rejectTransfer,
            recursivePolicy: .none,
            crossRuntimePolicy: .sameRuntimeOnly
        )

        #expect(request.retainedByteCount == RemoteTransferBounds.maximumJobRetainedByteCount)
    }

    @Test("[APP-008] same-endpoint move charges endpoint material once at the exact request bound")
    func sameEndpointMoveChargesEndpointOnceAtExactBound() throws {
        let owner = transferOwner("11111111-1111-1111-1111-111111111111")
        let sourcePath = try remotePath("/source-move")
        let destinationPath = try remotePath("/destination-move")
        let endpoint = try endpointFillingRequestBound(
            owner: owner,
            id: "33333333-3333-3333-3333-333333333333",
            pathByteCount: sourcePath.rawBytes.count + destinationPath.rawBytes.count
        )

        let request = try RemoteTransferRequest(
            id: UUID(),
            owner: owner,
            kind: .remoteMove,
            requestedItems: [
                .init(logicalKey: .init(), source: .remote(endpoint: endpoint, path: sourcePath))
            ],
            destination: .remoteDirectory(endpoint: endpoint, path: destinationPath),
            collisionPolicy: .ask,
            metadataPolicy: .notApplicable,
            symlinkPolicy: .operateOnLinkIdentity,
            recursivePolicy: .none,
            crossRuntimePolicy: .sameRuntimeOnly
        )

        #expect(request.retainedByteCount == RemoteTransferBounds.maximumJobRetainedByteCount)
    }

    @Test("[APP-008] same-endpoint rename charges endpoint material once at the exact request bound")
    func sameEndpointRenameChargesEndpointOnceAtExactBound() throws {
        let owner = transferOwner("11111111-1111-1111-1111-111111111111")
        let sourcePath = try remotePath("/source-rename")
        let destinationPath = try remotePath("/destination-rename")
        let endpoint = try endpointFillingRequestBound(
            owner: owner,
            id: "44444444-4444-4444-4444-444444444444",
            pathByteCount: sourcePath.rawBytes.count + destinationPath.rawBytes.count
        )

        let request = try RemoteTransferRequest(
            id: UUID(),
            owner: owner,
            kind: .rename,
            requestedItems: [
                .init(logicalKey: .init(), source: .remote(endpoint: endpoint, path: sourcePath))
            ],
            destination: .remotePath(endpoint: endpoint, path: destinationPath),
            collisionPolicy: .ask,
            metadataPolicy: .notApplicable,
            symlinkPolicy: .operateOnLinkIdentity,
            recursivePolicy: .none,
            crossRuntimePolicy: .sameRuntimeOnly
        )

        #expect(request.retainedByteCount == RemoteTransferBounds.maximumJobRetainedByteCount)
    }

    @Test("[APP-008] cross-runtime copy charges each endpoint and every raw path exactly once")
    func crossRuntimeCopyChargesEachEndpointAndPathExactlyOnce() throws {
        let destinationOwner = transferOwner("11111111-1111-1111-1111-111111111111")
        let sourceOwner = transferOwner("55555555-5555-5555-5555-555555555555")
        let sourceEndpoint = try makeEndpoint(
            owner: sourceOwner,
            id: "66666666-6666-6666-6666-666666666666",
            retainedByteCount: 101
        )
        let destinationEndpoint = try makeEndpoint(
            owner: destinationOwner,
            id: "77777777-7777-7777-7777-777777777777",
            retainedByteCount: 202
        )
        let sourcePath = try remotePath("/cross-source")
        let destinationPath = try remotePath("/cross-destination")

        let request = try RemoteTransferRequest(
            id: UUID(),
            owner: destinationOwner,
            kind: .remoteCopy,
            requestedItems: [
                .init(
                    logicalKey: .init(),
                    source: .remote(endpoint: sourceEndpoint, path: sourcePath)
                )
            ],
            destination: .remoteDirectory(
                endpoint: destinationEndpoint,
                path: destinationPath
            ),
            collisionPolicy: .ask,
            metadataPolicy: .preserveSupportedPermissions,
            symlinkPolicy: .rejectTransfer,
            recursivePolicy: .none,
            crossRuntimePolicy: .destinationOwnedCopy(sourceOwner: sourceOwner)
        )

        let expected = sourceEndpoint.retainedByteCount
            + destinationEndpoint.retainedByteCount
            + sourcePath.rawBytes.count
            + destinationPath.rawBytes.count
        #expect(request.retainedByteCount == expected)
    }

    @Test("[FILE-XFER-003] recursive policy depth and pending directory bounds are exact")
    func recursivePolicyBoundsAreExact() throws {
        _ = try RemoteTransferRecursivePolicy.validatedBounded(
            maximumItems: 20_000,
            maximumDepth: 128,
            maximumPendingDirectories: 1_024
        )

        #expect(throws: RemoteFileError(category: .limitExceeded)) {
            try RemoteTransferRecursivePolicy.validatedBounded(
                maximumItems: 20_001,
                maximumDepth: 128,
                maximumPendingDirectories: 1_024
            )
        }
        #expect(throws: RemoteFileError(category: .limitExceeded)) {
            try RemoteTransferRecursivePolicy.validatedBounded(
                maximumItems: 20_000,
                maximumDepth: 129,
                maximumPendingDirectories: 1_024
            )
        }
        #expect(throws: RemoteFileError(category: .limitExceeded)) {
            try RemoteTransferRecursivePolicy.validatedBounded(
                maximumItems: 20_000,
                maximumDepth: 128,
                maximumPendingDirectories: 1_025
            )
        }
    }

    @Test("[FILE-XFER-003] work item relative component bound is exact")
    func workItemKeyRelativeComponentBoundIsExact() throws {
        let topLevel = RemoteTransferLogicalItemKey()
        let components = try (0..<RemoteTransferBounds.maximumWorkItemRelativeComponentCount)
            .map { try component("c\($0)") }
        _ = try RemoteTransferWorkItemKey(topLevelKey: topLevel, relativeRawComponents: components)

        #expect(throws: RemoteFileError(category: .limitExceeded)) {
            _ = try RemoteTransferWorkItemKey(
                topLevelKey: topLevel,
                relativeRawComponents: components + [component("overflow")]
            )
        }
    }

    @Test("[FILE-XFER-003] work item relative raw path byte budget is exact")
    func workItemKeyRelativeRawPathByteBudgetIsExact() throws {
        let topLevel = RemoteTransferLogicalItemKey()
        let componentBytes = Array(String(repeating: "r", count: 4 * 1_024).utf8)
        let components = try (0..<8).map { _ in
            try RemotePathComponent(rawBytes: componentBytes)
        }
        _ = try RemoteTransferWorkItemKey(
            topLevelKey: topLevel,
            relativeRawComponents: components
        )

        #expect(throws: RemoteFileError(category: .limitExceeded)) {
            _ = try RemoteTransferWorkItemKey(
                topLevelKey: topLevel,
                relativeRawComponents: components + [
                    RemotePathComponent(rawBytes: [UInt8(ascii: "x")])
                ]
            )
        }
    }

    @Test("[FILE-XFER-003] checkpoint and cleanup manifests enforce job bounds")
    func checkpointAndCleanupJobBoundsAreExact() throws {
        let topLevel = RemoteTransferLogicalItemKey()
        let checkpoints = try (0..<RemoteTransferBounds.maximumWorkCheckpointFailureRecordsPerJob).map {
            RemoteTransferCheckpoint(
                key: try RemoteTransferWorkItemKey(
                    topLevelKey: topLevel,
                    relativeRawComponents: [component("item-\($0)")]
                ),
                disposition: .discovered
            )
        }
        _ = try RemoteTransferCheckpointManifest(checkpoints: checkpoints, cleanupEntries: [])
        #expect(throws: RemoteFileError(category: .invalidOperation)) {
            _ = try RemoteTransferCheckpointManifest(
                checkpoints: [checkpoints[0], checkpoints[0]],
                cleanupEntries: []
            )
        }

        #expect(throws: RemoteFileError(category: .limitExceeded)) {
            _ = try RemoteTransferCheckpointManifest(
                checkpoints: checkpoints + [RemoteTransferCheckpoint(
                    key: try RemoteTransferWorkItemKey(
                        topLevelKey: topLevel,
                        relativeRawComponents: [component("overflow")]
                    ),
                    disposition: .unstarted
                )],
                cleanupEntries: []
            )
        }

        let attempt = try RemoteTransferAttemptIdentity(id: UUID(), generation: 1)
        let cleanup = try (0..<RemoteTransferBounds.maximumCleanupEntriesPerJob).map {
            RemoteTransferCleanupEntry(
                attempt: attempt,
                workItemKey: try RemoteTransferWorkItemKey(
                    topLevelKey: topLevel,
                    relativeRawComponents: [component("cleanup-\($0)")]
                ),
                location: .remote(endpointID: UUID(), path: try remotePath("/tmp/\($0)"))
            )
        }
        _ = try RemoteTransferCheckpointManifest(checkpoints: [], cleanupEntries: cleanup)
        #expect(try RemoteTransferCheckpointManifest(checkpoints: [], cleanupEntries: cleanup).retainedByteCount > 0)
        #expect(throws: RemoteFileError(category: .invalidOperation)) {
            _ = try RemoteTransferCheckpointManifest(
                checkpoints: [],
                cleanupEntries: [cleanup[0], cleanup[0]]
            )
        }
        #expect(throws: RemoteFileError(category: .limitExceeded)) {
            _ = try RemoteTransferCheckpointManifest(
                checkpoints: [],
                cleanupEntries: cleanup + [cleanup[0]]
            )
        }
    }

    @Test("[FILE-XFER-003] checkpoint manifest retained bytes are capped")
    func checkpointManifestRetainedBytesAreCapped() throws {
        let topLevel = RemoteTransferLogicalItemKey()
        let key = try RemoteTransferWorkItemKey(
            topLevelKey: topLevel,
            relativeRawComponents: [component("item")]
        )
        let longMessage = String(repeating: "e", count: RemoteFileError.maximumUserFacingMessageByteCount)
        let checkpoints = (0..<263).map { _ in
            RemoteTransferCheckpoint(
                key: key,
                disposition: .failed(RemoteFileError(category: .timeout, userFacingMessage: longMessage))
            )
        }

        #expect(throws: RemoteFileError(category: .invalidOperation)) {
            _ = try RemoteTransferCheckpointManifest(checkpoints: checkpoints, cleanupEntries: [])
        }

        let uniqueCheckpoints = try (0..<263).map {
            RemoteTransferCheckpoint(
                key: try RemoteTransferWorkItemKey(
                    topLevelKey: topLevel,
                    relativeRawComponents: [component("item-\($0)")]
                ),
                disposition: .failed(RemoteFileError(category: .timeout, userFacingMessage: longMessage))
            )
        }
        #expect(throws: RemoteFileError(category: .limitExceeded)) {
            _ = try RemoteTransferCheckpointManifest(checkpoints: uniqueCheckpoints, cleanupEntries: [])
        }
    }

    @Test("[FILE-XFER-003] combined discovered checkpoint failure count is checked")
    func combinedWorkRecordCountIsChecked() throws {
        _ = try RemoteTransferWorkRecordCounts(
            discoveredWorkItems: 10_000,
            checkpoints: 5_000,
            itemFailures: 5_000
        )

        #expect(throws: RemoteFileError(category: .limitExceeded)) {
            try RemoteTransferWorkRecordCounts(
                discoveredWorkItems: 10_000,
                checkpoints: 5_000,
                itemFailures: 5_001
            )
        }
        #expect(throws: RemoteFileError(category: .limitExceeded)) {
            try RemoteTransferWorkRecordCounts(
                discoveredWorkItems: Int.max,
                checkpoints: 1,
                itemFailures: 0
            )
        }
    }

    @Test("[FILE-XFER-003] work record count maximum cannot be weakened by callers")
    func workRecordCountMaximumCannotBeWeakened() throws {
        _ = try RemoteTransferWorkRecordCounts(
            discoveredWorkItems: 20_000,
            checkpoints: 0,
            itemFailures: 0
        )
    }

    @Test("[APP-008] a job retains at most one current collision")
    func currentCollisionBoundIsOne() throws {
        let first = RemoteTransferCollisionSummary(
            logicalItemKey: RemoteTransferLogicalItemKey(),
            destinationSummary: try RemoteTransferPresentationText("/first")
        )
        let second = RemoteTransferCollisionSummary(
            logicalItemKey: RemoteTransferLogicalItemKey(),
            destinationSummary: try RemoteTransferPresentationText("/second")
        )

        _ = try RemoteTransferCurrentCollision(collisions: [first])
        let empty = try RemoteTransferCurrentCollision(collisions: [])
        #expect(empty.collision == nil)
        #expect(throws: RemoteFileError(category: .limitExceeded)) {
            try RemoteTransferCurrentCollision(collisions: [first, second])
        }
    }

    @Test("[APP-008] engine-level aggregate bounds use checked addition")
    func aggregateBoundsUseCheckedAddition() throws {
        _ = try RemoteTransferAggregateCounts(
            nonterminalJobs: 1_000,
            terminalRecords: 500,
            workCheckpointFailureRecords: 40_000,
            cleanupEntries: 80_000
        )

        #expect(throws: RemoteFileError(category: .limitExceeded)) {
            _ = try RemoteTransferAggregateCounts(
                nonterminalJobs: 1_001,
                terminalRecords: 500,
                workCheckpointFailureRecords: 40_000,
                cleanupEntries: 80_000
            )
        }
        #expect(throws: RemoteFileError(category: .limitExceeded)) {
            _ = try RemoteTransferAggregateCounts(
                nonterminalJobs: 1_000,
                terminalRecords: 501,
                workCheckpointFailureRecords: 40_000,
                cleanupEntries: 80_000
            )
        }
        #expect(throws: RemoteFileError(category: .limitExceeded)) {
            _ = try RemoteTransferAggregateCounts(
                nonterminalJobs: 1_000,
                terminalRecords: 500,
                workCheckpointFailureRecords: 40_001,
                cleanupEntries: 80_000
            )
        }
        #expect(throws: RemoteFileError(category: .limitExceeded)) {
            _ = try RemoteTransferAggregateCounts(
                nonterminalJobs: 1_000,
                terminalRecords: 500,
                workCheckpointFailureRecords: 40_000,
                cleanupEntries: 80_001
            )
        }
        #expect(throws: RemoteFileError(category: .limitExceeded)) {
            _ = try RemoteTransferAggregateCounts(
                nonterminalJobs: Int.max,
                terminalRecords: 1,
                workCheckpointFailureRecords: 0,
                cleanupEntries: 0
            )
        }
        #expect(throws: RemoteFileError(category: .limitExceeded)) {
            try RemoteTransferAggregateCounts.checkedSum(Int.max, 1)
        }
    }

    @Test("[APP-008] variable retained data budgets are enforced per job and engine")
    func retainedDataBudgetsAreExact() throws {
        _ = try RemoteTransferRetainedDataBudget(
            jobRetainedByteCount: 16 * 1_024 * 1_024,
            engineRetainedByteCount: 64 * 1_024 * 1_024
        )

        #expect(throws: RemoteFileError(category: .limitExceeded)) {
            try RemoteTransferRetainedDataBudget(
                jobRetainedByteCount: 16 * 1_024 * 1_024 + 1,
                engineRetainedByteCount: 64 * 1_024 * 1_024
            )
        }
        #expect(throws: RemoteFileError(category: .limitExceeded)) {
            try RemoteTransferRetainedDataBudget(
                jobRetainedByteCount: 16 * 1_024 * 1_024,
                engineRetainedByteCount: 64 * 1_024 * 1_024 + 1
            )
        }
    }

    @Test("[APP-008] safe failure arrays are bounded and unique")
    func safeFailureArraysAreBoundedAndUnique() throws {
        let failures = (0..<RemoteTransferBounds.maximumSafeFailuresPerSnapshot).map { _ in
            RemoteTransferItemFailure(
                logicalItemKey: RemoteTransferLogicalItemKey(),
                error: RemoteFileError(category: .timeout)
            )
        }
        _ = try RemoteTransferSafeFailureList(failures)

        #expect(throws: RemoteFileError(category: .limitExceeded)) {
            try RemoteTransferSafeFailureList(failures + [
                RemoteTransferItemFailure(
                    logicalItemKey: RemoteTransferLogicalItemKey(),
                    error: RemoteFileError(category: .timeout)
                )
            ])
        }
        #expect(throws: RemoteFileError(category: .invalidOperation)) {
            try RemoteTransferSafeFailureList([failures[0], failures[0]])
        }
    }

    @Test("[APP-008] safe failure list retained bytes are capped")
    func safeFailureListRetainedBytesAreCapped() {
        let longMessage = String(repeating: "f", count: RemoteFileError.maximumUserFacingMessageByteCount)
        let failures = (0..<263).map { _ in
            RemoteTransferItemFailure(
                logicalItemKey: RemoteTransferLogicalItemKey(),
                error: RemoteFileError(category: .timeout, userFacingMessage: longMessage)
            )
        }
        #expect(throws: RemoteFileError(category: .limitExceeded)) {
            try RemoteTransferSafeFailureList(failures)
        }
    }

    @Test("[FILE-XFER-003] attempt generation exhaustion fails as limit exceeded")
    func attemptGenerationExhaustionIsLimitExceeded() throws {
        let exhausted = try RemoteTransferAttemptIdentity(id: UUID(), generation: UInt64.max)
        #expect(throws: RemoteFileError(category: .limitExceeded)) {
            try exhausted.nextAttempt(id: UUID())
        }
    }

    @Test("[FILE-XFER-003] attempt generation starts at one and rejects same UUID")
    func attemptGenerationStartsAtOneAndRejectsSameUUID() {
        let id = UUID()
        #expect(throws: RemoteFileError(category: .limitExceeded)) {
            try RemoteTransferAttemptIdentity(id: id, generation: 0)
        }
        #expect(throws: RemoteFileError(category: .invalidOperation)) {
            try RemoteTransferAttemptIdentity(id: id, generation: 1).nextAttempt(id: id)
        }
    }

    @Test("[APP-008] timestamps and counters validate monotonic invariants")
    func timestampsAndCountersValidateMonotonicInvariants() throws {
        #expect(throws: RemoteFileError(category: .invalidOperation)) {
            try RemoteTransferTimestamps(
                createdAtNanoseconds: 10,
                startedAtNanoseconds: 9,
                updatedAtNanoseconds: 10,
                settledAtNanoseconds: nil
            )
        }
        #expect(throws: RemoteFileError(category: .invalidOperation)) {
            try RemoteTransferJobSnapshot(
                id: UUID(),
                attempt: try RemoteTransferAttemptIdentity(id: UUID(), generation: 1),
                kind: .download,
                state: .running,
                sourceSummary: RemoteTransferPresentationText("source"),
                destinationSummary: RemoteTransferPresentationText("dest"),
                currentItemDisplay: nil,
                bytesCompleted: 2,
                bytesTotal: 1,
                itemsCompleted: 0,
                itemsTotal: nil,
                canRetry: false,
                timestamps: try RemoteTransferTimestamps(
                    createdAtNanoseconds: 1,
                    startedAtNanoseconds: 1,
                    updatedAtNanoseconds: 1,
                    settledAtNanoseconds: nil
                )
            )
        }
    }

    private func uploadRequest(
        itemCount: Int,
        owner: RemoteTransferOwnerIdentity,
        endpoint: RemoteTransferEndpointSnapshot
    ) throws -> RemoteTransferRequest {
        try RemoteTransferRequest(
            id: UUID(),
            owner: owner,
            kind: .upload,
            requestedItems: (0..<itemCount).map {
                RemoteTransferRequestedItem(
                    logicalKey: RemoteTransferLogicalItemKey(),
                    source: .local(try localIdentity("/tmp/item-\($0)", kind: .regularFile))
                )
            },
            destination: .remoteDirectory(endpoint: endpoint, path: remotePath("/drop")),
            collisionPolicy: .ask,
            metadataPolicy: .preserveSupportedPermissions,
            symlinkPolicy: .rejectTransfer,
            recursivePolicy: .none,
            crossRuntimePolicy: .sameRuntimeOnly
        )
    }
}
