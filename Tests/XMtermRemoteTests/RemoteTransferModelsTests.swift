import Foundation
import Testing
import XMtermCore

@testable import XMtermRemote

@Suite("Remote transfer model contracts")
struct RemoteTransferModelsTests {
    @Test("[FILE-XFER-001, SESS-011] request carries complete executable identity")
    func requestCarriesCompleteExecutionIdentity() throws {
        let owner = transferOwner("11111111-1111-1111-1111-111111111111")
        let endpoint = try makeEndpoint(owner: owner, id: "22222222-2222-2222-2222-222222222222")
        let local = try localIdentity("/tmp/upload.txt", kind: .regularFile)
        let key = RemoteTransferLogicalItemKey(uuid("33333333-3333-3333-3333-333333333333"))

        let request = try RemoteTransferRequest(
            id: uuid("44444444-4444-4444-4444-444444444444"),
            owner: owner,
            kind: .upload,
            requestedItems: [.init(logicalKey: key, source: .local(local))],
            destination: .remoteDirectory(endpoint: endpoint, path: remotePath("/drop")),
            collisionPolicy: .ask,
            metadataPolicy: .preserveSupportedPermissions,
            symlinkPolicy: .rejectTransfer,
            recursivePolicy: .bounded(maximumItems: 20_000, maximumDepth: 128, maximumPendingDirectories: 1_024),
            crossRuntimePolicy: .sameRuntimeOnly
        )

        #expect(request.id == uuid("44444444-4444-4444-4444-444444444444"))
        #expect(request.owner == owner)
        #expect(request.kind == .upload)
        #expect(request.requestedItems == [.init(logicalKey: key, source: .local(local))])
        let expectedDestination = try RemoteTransferDestination.remoteDirectory(
            endpoint: endpoint,
            path: remotePath("/drop")
        )
        #expect(request.destination == expectedDestination)
        #expect(request.logicalItemKeys == [key])
    }

    @Test("[FILE-XFER-001] operation matrix rejects owner and policy mismatches")
    func rejectsOwnerAndPolicyMismatch() throws {
        let sourceOwner = transferOwner("11111111-1111-1111-1111-111111111111")
        let destinationOwner = transferOwner("22222222-2222-2222-2222-222222222222")
        let sourceEndpoint = try makeEndpoint(owner: sourceOwner, id: "33333333-3333-3333-3333-333333333333")
        let destinationEndpoint = try makeEndpoint(owner: destinationOwner, id: "44444444-4444-4444-4444-444444444444")
        let remoteItem = RemoteTransferRequestedItem(
            logicalKey: RemoteTransferLogicalItemKey(),
            source: .remote(endpoint: sourceEndpoint, path: try remotePath("/source"))
        )

        #expect(throws: RemoteFileError(category: .invalidOperation)) {
            try RemoteTransferRequest(
                id: UUID(),
                owner: sourceOwner,
                kind: .download,
                requestedItems: [remoteItem],
                destination: .remoteDirectory(endpoint: sourceEndpoint, path: remotePath("/not-local")),
                collisionPolicy: .ask,
                metadataPolicy: .notApplicable,
                symlinkPolicy: .rejectTransfer,
                recursivePolicy: .none,
                crossRuntimePolicy: .sameRuntimeOnly
            )
        }

        #expect(throws: RemoteFileError(category: .invalidOperation)) {
            try RemoteTransferRequest(
                id: UUID(),
                owner: destinationOwner,
                kind: .remoteMove,
                requestedItems: [remoteItem],
                destination: .remoteDirectory(endpoint: destinationEndpoint, path: remotePath("/drop")),
                collisionPolicy: .ask,
                metadataPolicy: .preserveSupportedPermissions,
                symlinkPolicy: .operateOnLinkIdentity,
                recursivePolicy: .none,
                crossRuntimePolicy: .destinationOwnedCopy(sourceOwner: sourceOwner)
            )
        }

        _ = try RemoteTransferRequest(
            id: UUID(),
            owner: destinationOwner,
            kind: .remoteCopy,
            requestedItems: [remoteItem],
            destination: .remoteDirectory(endpoint: destinationEndpoint, path: remotePath("/drop")),
            collisionPolicy: .ask,
            metadataPolicy: .preserveSupportedPermissions,
            symlinkPolicy: .rejectTransfer,
            recursivePolicy: .none,
            crossRuntimePolicy: .destinationOwnedCopy(sourceOwner: sourceOwner)
        )
    }

    @Test("[FILE-XFER-001] operation matrix admits every valid Task 3A row")
    func operationMatrixAdmitsAllValidRows() throws {
        let owner = transferOwner("11111111-1111-1111-1111-111111111111")
        let sourceOwner = transferOwner("99999999-9999-9999-9999-999999999999")
        let endpoint = try makeEndpoint(owner: owner, id: "22222222-2222-2222-2222-222222222222")
        let sourceEndpoint = try makeEndpoint(owner: sourceOwner, id: "33333333-3333-3333-3333-333333333333")
        let localDirectory = try localIdentity("/tmp/downloads", kind: .directory)

        let requests = try [
            RemoteTransferRequest(
                id: UUID(),
                owner: owner,
                kind: .upload,
                requestedItems: [.init(logicalKey: .init(), source: .local(try localIdentity("/tmp/a", kind: .regularFile)))],
                destination: .remoteDirectory(endpoint: endpoint, path: remotePath("/drop")),
                collisionPolicy: .ask,
                metadataPolicy: .preserveSupportedPermissions,
                symlinkPolicy: .rejectTransfer,
                recursivePolicy: .none,
                crossRuntimePolicy: .sameRuntimeOnly
            ),
            RemoteTransferRequest(
                id: UUID(),
                owner: owner,
                kind: .download,
                requestedItems: [.init(logicalKey: .init(), source: .remote(endpoint: endpoint, path: remotePath("/a")))],
                destination: .localDirectory(localDirectory),
                collisionPolicy: .ask,
                metadataPolicy: .preserveSupportedPermissions,
                symlinkPolicy: .rejectTransfer,
                recursivePolicy: .none,
                crossRuntimePolicy: .sameRuntimeOnly
            ),
            RemoteTransferRequest(
                id: UUID(),
                owner: owner,
                kind: .remoteCopy,
                requestedItems: [.init(logicalKey: .init(), source: .remote(endpoint: sourceEndpoint, path: remotePath("/a")))],
                destination: .remoteDirectory(endpoint: endpoint, path: remotePath("/drop")),
                collisionPolicy: .keepBoth,
                metadataPolicy: .preserveSupportedPermissions,
                symlinkPolicy: .rejectTransfer,
                recursivePolicy: .none,
                crossRuntimePolicy: .destinationOwnedCopy(sourceOwner: sourceOwner)
            ),
            RemoteTransferRequest(
                id: UUID(),
                owner: owner,
                kind: .remoteMove,
                requestedItems: [.init(logicalKey: .init(), source: .remote(endpoint: endpoint, path: remotePath("/a")))],
                destination: .remoteDirectory(endpoint: endpoint, path: remotePath("/drop")),
                collisionPolicy: .ask,
                metadataPolicy: .notApplicable,
                symlinkPolicy: .operateOnLinkIdentity,
                recursivePolicy: .none,
                crossRuntimePolicy: .sameRuntimeOnly
            ),
            RemoteTransferRequest(
                id: UUID(),
                owner: owner,
                kind: .delete,
                requestedItems: [.init(logicalKey: .init(), source: .remote(endpoint: endpoint, path: remotePath("/a")))],
                destination: .none,
                collisionPolicy: .notApplicable,
                metadataPolicy: .notApplicable,
                symlinkPolicy: .operateOnLinkIdentity,
                recursivePolicy: .bounded(maximumItems: 20_000, maximumDepth: 128, maximumPendingDirectories: 1_024),
                crossRuntimePolicy: .sameRuntimeOnly
            ),
            RemoteTransferRequest(
                id: UUID(),
                owner: owner,
                kind: .createFile,
                requestedItems: [.init(logicalKey: .init(), source: .remote(endpoint: endpoint, path: remotePath("/new-file")))],
                destination: .none,
                collisionPolicy: .ask,
                metadataPolicy: .notApplicable,
                symlinkPolicy: .rejectTransfer,
                recursivePolicy: .none,
                crossRuntimePolicy: .sameRuntimeOnly
            ),
            RemoteTransferRequest(
                id: UUID(),
                owner: owner,
                kind: .createDirectory,
                requestedItems: [.init(logicalKey: .init(), source: .remote(endpoint: endpoint, path: remotePath("/new-directory")))],
                destination: .none,
                collisionPolicy: .ask,
                metadataPolicy: .notApplicable,
                symlinkPolicy: .rejectTransfer,
                recursivePolicy: .none,
                crossRuntimePolicy: .sameRuntimeOnly
            ),
            RemoteTransferRequest(
                id: UUID(),
                owner: owner,
                kind: .rename,
                requestedItems: [.init(logicalKey: .init(), source: .remote(endpoint: endpoint, path: remotePath("/old")))],
                destination: .remotePath(endpoint: endpoint, path: remotePath("/new")),
                collisionPolicy: .ask,
                metadataPolicy: .notApplicable,
                symlinkPolicy: .operateOnLinkIdentity,
                recursivePolicy: .none,
                crossRuntimePolicy: .sameRuntimeOnly
            )
        ]

        #expect(requests.map { $0.kind } == [
            RemoteTransferJobKind.upload,
            .download,
            .remoteCopy,
            .remoteMove,
            .delete,
            .createFile,
            .createDirectory,
            .rename
        ])
    }

    @Test("[FILE-XFER-001] zero items and duplicate logical keys are rejected before admission")
    func rejectsZeroItemsAndDuplicateLogicalKeys() throws {
        let owner = transferOwner("11111111-1111-1111-1111-111111111111")
        let endpoint = try makeEndpoint(owner: owner, id: "22222222-2222-2222-2222-222222222222")
        let key = RemoteTransferLogicalItemKey()
        let item = RemoteTransferRequestedItem(
            logicalKey: key,
            source: .remote(endpoint: endpoint, path: try remotePath("/a"))
        )

        #expect(throws: RemoteFileError(category: .invalidOperation)) {
            try RemoteTransferRequest(
                id: UUID(),
                owner: owner,
                kind: .delete,
                requestedItems: [],
                destination: .none,
                collisionPolicy: .notApplicable,
                metadataPolicy: .notApplicable,
                symlinkPolicy: .operateOnLinkIdentity,
                recursivePolicy: .none,
                crossRuntimePolicy: .sameRuntimeOnly
            )
        }
        #expect(throws: RemoteFileError(category: .invalidOperation)) {
            try RemoteTransferRequest(
                id: UUID(),
                owner: owner,
                kind: .delete,
                requestedItems: [item, item],
                destination: .none,
                collisionPolicy: .notApplicable,
                metadataPolicy: .notApplicable,
                symlinkPolicy: .operateOnLinkIdentity,
                recursivePolicy: .none,
                crossRuntimePolicy: .sameRuntimeOnly
            )
        }
    }

    @Test("[FILE-XFER-001, SESS-011] one job admits only one source endpoint plus the allowed destination endpoint")
    func rejectsMultipleSourceEndpointsAndMismatchedSameRuntimeDestinations() throws {
        let owner = transferOwner("11111111-1111-1111-1111-111111111111")
        let firstEndpoint = try makeEndpoint(owner: owner, id: "22222222-2222-2222-2222-222222222222")
        let secondEndpoint = try makeEndpoint(owner: owner, id: "33333333-3333-3333-3333-333333333333")
        let items = try [
            RemoteTransferRequestedItem(logicalKey: .init(), source: .remote(endpoint: firstEndpoint, path: remotePath("/a"))),
            RemoteTransferRequestedItem(logicalKey: .init(), source: .remote(endpoint: secondEndpoint, path: remotePath("/b")))
        ]

        #expect(throws: RemoteFileError(category: .invalidOperation)) {
            try RemoteTransferRequest(
                id: UUID(),
                owner: owner,
                kind: .download,
                requestedItems: items,
                destination: .localDirectory(try localIdentity("/tmp/downloads", kind: .directory)),
                collisionPolicy: .ask,
                metadataPolicy: .preserveSupportedPermissions,
                symlinkPolicy: .rejectTransfer,
                recursivePolicy: .none,
                crossRuntimePolicy: .sameRuntimeOnly
            )
        }

        #expect(throws: RemoteFileError(category: .invalidOperation)) {
            try RemoteTransferRequest(
                id: UUID(),
                owner: owner,
                kind: .remoteCopy,
                requestedItems: [.init(logicalKey: .init(), source: .remote(endpoint: firstEndpoint, path: remotePath("/a")))],
                destination: .remoteDirectory(endpoint: secondEndpoint, path: remotePath("/drop")),
                collisionPolicy: .ask,
                metadataPolicy: .preserveSupportedPermissions,
                symlinkPolicy: .rejectTransfer,
                recursivePolicy: .none,
                crossRuntimePolicy: .sameRuntimeOnly
            )
        }
    }

    @Test("[FILE-XFER-003] recursive item limit cannot be smaller than top-level request count")
    func recursiveMaximumItemsMustCoverRequestedItems() throws {
        let owner = transferOwner("11111111-1111-1111-1111-111111111111")
        let endpoint = try makeEndpoint(owner: owner, id: "22222222-2222-2222-2222-222222222222")

        #expect(throws: RemoteFileError(category: .limitExceeded)) {
            try RemoteTransferRequest(
                id: UUID(),
                owner: owner,
                kind: .delete,
                requestedItems: [
                    .init(logicalKey: .init(), source: .remote(endpoint: endpoint, path: remotePath("/a"))),
                    .init(logicalKey: .init(), source: .remote(endpoint: endpoint, path: remotePath("/b")))
                ],
                destination: .none,
                collisionPolicy: .notApplicable,
                metadataPolicy: .notApplicable,
                symlinkPolicy: .operateOnLinkIdentity,
                recursivePolicy: .bounded(maximumItems: 1, maximumDepth: 128, maximumPendingDirectories: 1_024),
                crossRuntimePolicy: .sameRuntimeOnly
            )
        }
    }

    @Test("[FILE-XFER-001] operation policies reject implicit collision and wrong metadata choices")
    func operationPoliciesRejectImplicitCollisionAndWrongMetadataChoices() throws {
        let owner = transferOwner("11111111-1111-1111-1111-111111111111")
        let endpoint = try makeEndpoint(owner: owner, id: "22222222-2222-2222-2222-222222222222")

        #expect(throws: RemoteFileError(category: .invalidOperation)) {
            try RemoteTransferRequest(
                id: UUID(),
                owner: owner,
                kind: .download,
                requestedItems: [.init(logicalKey: .init(), source: .remote(endpoint: endpoint, path: remotePath("/a")))],
                destination: .localDirectory(try localIdentity("/tmp/downloads", kind: .directory)),
                collisionPolicy: .notApplicable,
                metadataPolicy: .preserveSupportedPermissions,
                symlinkPolicy: .rejectTransfer,
                recursivePolicy: .none,
                crossRuntimePolicy: .sameRuntimeOnly
            )
        }
        #expect(throws: RemoteFileError(category: .invalidOperation)) {
            try RemoteTransferRequest(
                id: UUID(),
                owner: owner,
                kind: .upload,
                requestedItems: [.init(logicalKey: .init(), source: .local(try localIdentity("/tmp/a", kind: .regularFile)))],
                destination: .remoteDirectory(endpoint: endpoint, path: remotePath("/drop")),
                collisionPolicy: .ask,
                metadataPolicy: .notApplicable,
                symlinkPolicy: .rejectTransfer,
                recursivePolicy: .none,
                crossRuntimePolicy: .sameRuntimeOnly
            )
        }
        #expect(throws: RemoteFileError(category: .invalidOperation)) {
            try RemoteTransferRequest(
                id: UUID(),
                owner: owner,
                kind: .remoteMove,
                requestedItems: [.init(logicalKey: .init(), source: .remote(endpoint: endpoint, path: remotePath("/a")))],
                destination: .remoteDirectory(endpoint: endpoint, path: remotePath("/drop")),
                collisionPolicy: .ask,
                metadataPolicy: .preserveSupportedPermissions,
                symlinkPolicy: .operateOnLinkIdentity,
                recursivePolicy: .none,
                crossRuntimePolicy: .sameRuntimeOnly
            )
        }
    }

    @Test("[FILE-OPS-001] create requires ask collision policy and rejects replacement policies")
    func createRequiresAskCollisionPolicy() throws {
        let owner = transferOwner("11111111-1111-1111-1111-111111111111")
        let endpoint = try makeEndpoint(owner: owner, id: "22222222-2222-2222-2222-222222222222")
        for policy in [
            RemoteTransferCollisionPolicy.notApplicable,
            .replace,
            .skip,
            .keepBoth
        ] {
            #expect(throws: RemoteFileError(category: .invalidOperation)) {
                try RemoteTransferRequest(
                    id: UUID(),
                    owner: owner,
                    kind: .createFile,
                    requestedItems: [.init(logicalKey: .init(), source: .remote(endpoint: endpoint, path: remotePath("/new")))],
                    destination: .none,
                    collisionPolicy: policy,
                    metadataPolicy: .notApplicable,
                    symlinkPolicy: .rejectTransfer,
                    recursivePolicy: .none,
                    crossRuntimePolicy: .sameRuntimeOnly
                )
            }
        }
    }

    @Test("[SESS-011] endpoint snapshot is independent of later workspace mutation")
    func endpointSnapshotIsIndependentOfWorkspaceMutation() throws {
        let originalOwner = transferOwner("11111111-1111-1111-1111-111111111111")
        var mutableWorkspaceOwner = originalOwner
        let snapshot = try makeEndpoint(owner: mutableWorkspaceOwner, id: "22222222-2222-2222-2222-222222222222")

        mutableWorkspaceOwner = transferOwner("33333333-3333-3333-3333-333333333333")

        #expect(snapshot.owner == originalOwner)
        #expect(snapshot.owner != mutableWorkspaceOwner)
        #expect(snapshot.summary.displayName.value == "Relay")
    }

    @Test("[FILE-XFER-001] admitted request needs no lookup table")
    func admittedRequestNeedsNoLookup() throws {
        let owner = transferOwner("11111111-1111-1111-1111-111111111111")
        let endpoint = try makeEndpoint(owner: owner, id: "22222222-2222-2222-2222-222222222222")
        let key = RemoteTransferLogicalItemKey()
        let request = try RemoteTransferRequest(
            id: UUID(),
            owner: owner,
            kind: .rename,
            requestedItems: [
                .init(logicalKey: key, source: .remote(endpoint: endpoint, path: remotePath("/old")))
            ],
            destination: .remotePath(endpoint: endpoint, path: remotePath("/new")),
            collisionPolicy: .ask,
            metadataPolicy: .notApplicable,
            symlinkPolicy: .operateOnLinkIdentity,
            recursivePolicy: .none,
            crossRuntimePolicy: .sameRuntimeOnly
        )

        guard case let .remote(capturedEndpoint, capturedPath) = request.requestedItems[0].source else {
            Issue.record("Expected remote source")
            return
        }
        #expect(capturedEndpoint == endpoint)
        let oldPath = try remotePath("/old")
        #expect(capturedPath == oldPath)
        let expectedDestination = try RemoteTransferDestination.remotePath(
            endpoint: endpoint,
            path: remotePath("/new")
        )
        #expect(request.destination == expectedDestination)
        #expect(request.logicalItemKeys == [key])
    }

    @Test("[APP-007, FILE-XFER-003] attempts use UUID plus checked generation")
    func attemptGenerationRejectsStaleCallbacks() throws {
        let first = try RemoteTransferAttemptIdentity(
            id: uuid("11111111-1111-1111-1111-111111111111"),
            generation: 1
        )
        let second = try first.nextAttempt(id: uuid("22222222-2222-2222-2222-222222222222"))

        #expect(second.generation == 2)
        #expect(second.id != first.id)
        #expect(second.matches(id: second.id, generation: second.generation))
        #expect(!second.matches(id: first.id, generation: second.generation))
        #expect(!second.matches(id: second.id, generation: first.generation))
    }

    @Test("[FILE-XFER-003] ten thousand generated attempts retain only current identity")
    func tenThousandAttemptGenerationsRemainConstantMemory() throws {
        var attempt = try RemoteTransferAttemptIdentity(id: UUID(), generation: 1)

        for index in 0..<10_000 {
            attempt = try attempt.nextAttempt(
                id: UUID(uuidString: String(format: "AAAAAAAA-AAAA-AAAA-AAAA-%012d", index))!
            )
        }

        #expect(attempt.generation == 10_001)
        #expect(MemoryLayout<RemoteTransferAttemptIdentity>.size <= 32)
    }

    @Test("[FILE-XFER-003] retry plan excludes committed descendants and restarts files from zero")
    func checkpointRetryExcludesCommittedDescendantsAndRestartsFilesFromZero() throws {
        let topLevel = RemoteTransferLogicalItemKey()
        let committed = try RemoteTransferWorkItemKey(
            topLevelKey: topLevel,
            relativeRawComponents: [component("done.txt")]
        )
        let failed = try RemoteTransferWorkItemKey(
            topLevelKey: topLevel,
            relativeRawComponents: [component("retry.txt")]
        )
        let manifest = try RemoteTransferCheckpointManifest(
            checkpoints: [
                .init(key: committed, disposition: .committed),
                .init(key: failed, disposition: .failed(RemoteFileError(category: .timeout))),
                .init(
                    key: try RemoteTransferWorkItemKey(
                        topLevelKey: topLevel,
                        relativeRawComponents: [component("discovered.txt")]
                    ),
                    disposition: .discovered
                )
            ],
            cleanupEntries: []
        )

        let plan = manifest.retryPlan()

        #expect(plan.excludedCommittedKeys == [committed])
        #expect(plan.workToRestart.map(\.key).count == 2)
        #expect(plan.workToRestart.map(\.key).contains(failed))
        #expect(plan.workToRestart.allSatisfy { $0.restartByteOffset == 0 })
    }

    @Test("[APP-008] request accounting includes endpoint material and local identities")
    func requestRetainedByteAccountingIncludesEndpointMaterialAndLocalIdentities() throws {
        let owner = transferOwner("11111111-1111-1111-1111-111111111111")
        let endpoint = try makeEndpoint(
            owner: owner,
            id: "22222222-2222-2222-2222-222222222222",
            retainedByteCount: 1_024
        )
        let local = try RemoteTransferLocalFileIdentity(
            url: URL(fileURLWithPath: "/tmp/a"),
            fileResourceIdentifier: Data(repeating: 1, count: 16),
            volumeIdentifier: Data(repeating: 2, count: 32),
            kind: .regularFile,
            observedSize: nil,
            observedModificationNanoseconds: nil,
            securityScopedBookmark: Data(repeating: 3, count: 64)
        )
        let destinationPath = try remotePath("/drop")
        let request = try RemoteTransferRequest(
            id: UUID(),
            owner: owner,
            kind: .upload,
            requestedItems: [.init(logicalKey: .init(), source: .local(local))],
            destination: .remoteDirectory(endpoint: endpoint, path: destinationPath),
            collisionPolicy: .ask,
            metadataPolicy: .preserveSupportedPermissions,
            symlinkPolicy: .rejectTransfer,
            recursivePolicy: .none,
            crossRuntimePolicy: .sameRuntimeOnly
        )

        #expect(
            request.retainedByteCount
                == endpoint.retainedByteCount
                    + local.retainedByteCount
                    + destinationPath.rawBytes.count
        )
    }

    @Test("[APP-008, MAC-006] presentation snapshot redacts executable material and raw identities")
    func presentationSnapshotIsBoundedAndRedacted() throws {
        let attempt = try RemoteTransferAttemptIdentity(id: UUID(), generation: 1)
        let collision = try RemoteTransferCollisionSummary(
            logicalItemKey: RemoteTransferLogicalItemKey(),
            destinationSummary: RemoteTransferPresentationText("/safe/redacted")
        )
        let snapshot = try RemoteTransferJobSnapshot(
            id: UUID(),
            attempt: attempt,
            kind: .download,
            state: .queued,
            runningPhase: nil,
            sourceSummary: RemoteTransferPresentationText("remote source"),
            destinationSummary: RemoteTransferPresentationText("Downloads"),
            currentItemDisplay: RemoteTransferPresentationText("file.txt"),
            bytesCompleted: 0,
            bytesTotal: nil,
            itemsCompleted: 0,
            itemsTotal: nil,
            itemFailures: [],
            collision: collision,
            canRetry: false,
            timestamps: try RemoteTransferTimestamps(
                createdAtNanoseconds: 1,
                startedAtNanoseconds: nil,
                updatedAtNanoseconds: 1,
                settledAtNanoseconds: nil
            )
        )

        #expect(snapshot.attempt == attempt)
        #expect(snapshot.attemptID == attempt.id)
        #expect(snapshot.sourceSummary.value == "remote source")
        #expect(snapshot.destinationSummary.value == "Downloads")
        #expect(snapshot.currentItemDisplay?.value == "file.txt")
        #expect(snapshot.collision == collision)
    }
}

package struct TestTrustedTransferMaterial: RemoteTransferTrustedConnectionMaterial, Equatable {
    package let label: String
    package let retainedByteCount: Int
}

func transferOwner(_ runtimeID: String) -> RemoteTransferOwnerIdentity {
    RemoteTransferOwnerIdentity(
        runtimeID: TerminalSessionID(rawValue: uuid(runtimeID)),
        workspaceID: RemoteWorkspaceID(rawValue: uuid("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
    )
}

func makeEndpoint(
    owner: RemoteTransferOwnerIdentity,
    id: String,
    displayName: String = "Relay",
    retainedByteCount: Int = 0
) throws -> RemoteTransferEndpointSnapshot {
    try RemoteTransferEndpointSnapshot(
        id: uuid(id),
        owner: owner,
        summary: RemoteTransferEndpointSummary(
            displayName: RemoteTransferPresentationText(displayName),
            kind: .packageTest
        ),
        trustedConnectionMaterial: TestTrustedTransferMaterial(
            label: displayName,
            retainedByteCount: retainedByteCount
        )
    )
}

func localIdentity(
    _ path: String,
    kind: RemoteTransferLocalItemKind,
    bookmark: Data? = nil
) throws -> RemoteTransferLocalFileIdentity {
    try RemoteTransferLocalFileIdentity(
        url: URL(fileURLWithPath: path),
        fileResourceIdentifier: Data("file-id:\(path)".utf8),
        volumeIdentifier: Data("volume".utf8),
        kind: kind,
        observedSize: 123,
        observedModificationNanoseconds: 456,
        securityScopedBookmark: bookmark
    )
}

func remotePath(_ value: String) throws -> RemotePath {
    try RemotePath(rawBytes: Array(value.utf8))
}

func endpointFillingRequestBound(
    owner: RemoteTransferOwnerIdentity,
    id: String,
    pathByteCount: Int,
    displayName: String = "Relay"
) throws -> RemoteTransferEndpointSnapshot {
    try makeEndpoint(
        owner: owner,
        id: id,
        displayName: displayName,
        retainedByteCount: RemoteTransferBounds.maximumJobRetainedByteCount
            - pathByteCount
            - displayName.utf8.count
    )
}

func component(_ value: String) throws -> RemotePathComponent {
    try RemotePathComponent(rawBytes: Array(value.utf8))
}

func uuid(_ value: String) -> UUID {
    UUID(uuidString: value)!
}
