import Foundation
import Testing

@testable import XMtermRemote

@Suite("Remote file provider contract")
struct RemoteFileProviderContractTests {
    @Test("A provider resolves its initial directory and lists immediate children only")
    func resolvesInitialDirectoryAndListsImmediateChildren() async throws {
        let home = try remotePath("/home/alice")
        let documents = try remotePath("/home/alice/Documents")
        let note = try entry("/home/alice/note.txt")
        let documentsEntry = try entry("/home/alice/Documents", kind: .directory)
        let nested = try entry("/home/alice/Documents/nested.txt")
        let provider = InMemoryRemoteFileProvider(
            initialDirectory: home,
            directoryGraph: [
                home: .init(entries: [note, documentsEntry], metadataCompleteness: .complete),
                documents: .init(entries: [nested], metadataCompleteness: .complete),
            ]
        )

        let resolved = try await resolveInitialDirectory(using: provider)
        let homeListing = try await provider.listDirectory(home)
        let documentsListing = try await provider.listDirectory(documents)

        #expect(resolved == home)
        #expect(homeListing.directory == home)
        #expect(homeListing.entries.map(\.path) == [documentsEntry.path, note.path])
        #expect(!homeListing.entries.contains(nested))
        #expect(documentsListing.entries == [nested])
    }

    @Test("An explicitly empty directory is a successful listing")
    func explicitEmptyDirectoryIsSuccess() async throws {
        let root = RemotePath.root
        let provider = InMemoryRemoteFileProvider(
            initialDirectory: root,
            directoryGraph: [
                root: .init(entries: [], metadataCompleteness: .complete),
            ]
        )

        let listing = try await provider.listDirectory(root)

        #expect(listing.directory == root)
        #expect(listing.entries.isEmpty)
        #expect(listing.metadataCompleteness == .complete)
    }

    @Test("The graph, deterministic responses, and published listings are immutable values")
    func graphResponsesAndPublishedListingsAreImmutableValues() async throws {
        let root = RemotePath.root
        let graphEntry = try entry("/graph.txt")
        let responseEntry = try entry("/response.txt")
        var graph: [RemotePath: InMemoryRemoteFileProvider.Directory] = [
            root: .init(entries: [graphEntry]),
        ]
        var responses = InMemoryRemoteFileProvider.DeterministicResponses(
            listings: [
                root: .success(.init(entries: [responseEntry], metadataCompleteness: .complete)),
            ]
        )
        let provider = InMemoryRemoteFileProvider(
            initialDirectory: root,
            directoryGraph: graph,
            deterministicResponses: responses
        )

        graph[root] = .init(entries: [])
        responses = .init()
        var firstResult = try await provider.listDirectory(root).entries
        firstResult.removeAll()
        let secondResult = try await provider.listDirectory(root).entries

        #expect(firstResult.isEmpty)
        #expect(secondResult == [responseEntry])
        #expect(graph[root]?.entries.isEmpty == true)
        #expect(responses.listings.isEmpty)
    }

    @Test("Every typed provider failure can be returned deterministically", arguments: RemoteFileError.Category.allCases)
    func returnsEveryTypedFailure(category: RemoteFileError.Category) async throws {
        let root = RemotePath.root
        let expected = RemoteFileError(category: category, userFacingMessage: "Deterministic failure")
        let provider = InMemoryRemoteFileProvider(
            initialDirectory: root,
            directoryGraph: [root: .init(entries: [])],
            deterministicResponses: .init(listings: [root: .failure(expected)])
        )

        let error = try await requireRemoteFileError {
            try await provider.listDirectory(root)
        }

        #expect(error == expected)
    }

    @Test("Recorded attempt kinds contain no requested path and instances stay independent")
    func recordsPathFreeAttemptsAndKeepsInstancesIndependent() async throws {
        let firstRoot = try remotePath("/first")
        let secondRoot = try remotePath("/second")
        let secret = try remotePath("/private/customer-secret")
        let first = InMemoryRemoteFileProvider(
            initialDirectory: firstRoot,
            directoryGraph: [firstRoot: .init(entries: [])]
        )
        let second = InMemoryRemoteFileProvider(
            initialDirectory: secondRoot,
            directoryGraph: [secondRoot: .init(entries: [])]
        )

        _ = try await first.resolveInitialDirectory()
        _ = try await requireRemoteFileError {
            try await first.listDirectory(secret)
        }
        _ = try await second.resolveInitialDirectory()
        let firstAttempts = await first.recordedAttempts
        let secondAttempts = await second.recordedAttempts

        #expect(firstAttempts == [.resolveInitialDirectory, .listDirectory])
        #expect(secondAttempts == [.resolveInitialDirectory])
        #expect(!String(reflecting: firstAttempts).contains("customer-secret"))

        await first.close()
        #expect(try await second.resolveInitialDirectory() == secondRoot)
    }

    @Test("Configured latency delays request completion")
    func configurableLatencyDelaysCompletion() async throws {
        let clock = ContinuousClock()
        let provider = InMemoryRemoteFileProvider(
            initialDirectory: .root,
            directoryGraph: [.root: .init(entries: [])],
            latency: .milliseconds(30)
        )
        let start = clock.now

        _ = try await provider.resolveInitialDirectory()

        #expect(start.duration(to: clock.now) >= .milliseconds(15))
    }

    @Test("Caller cancellation cancels the internal latency task")
    func callerCancellationCancelsRequest() async throws {
        let provider = delayedProvider()
        let request = Task {
            try await provider.resolveInitialDirectory()
        }
        await waitForAttempt(on: provider)

        request.cancel()
        let error = try await requireRemoteFileError {
            try await request.value
        }

        #expect(error.category == .cancelled)
    }

    @Test("cancelAll cancels every active internal request")
    func cancelAllCancelsActiveRequests() async throws {
        let provider = delayedProvider()
        let first = Task { try await provider.resolveInitialDirectory() }
        let second = Task { try await provider.listDirectory(.root) }
        await waitForAttempt(on: provider, count: 2)

        await provider.cancelAll()
        let firstError = try await requireRemoteFileError { try await first.value }
        let secondError = try await requireRemoteFileError { try await second.value }

        #expect(firstError.category == .cancelled)
        #expect(secondError.category == .cancelled)
    }

    @Test("close cancels active work and rejects all new work")
    func closeCancelsActiveAndRejectsNewWork() async throws {
        let provider = delayedProvider()
        let active = Task { try await provider.listDirectory(.root) }
        await waitForAttempt(on: provider)

        await provider.close()
        let activeError = try await requireRemoteFileError { try await active.value }
        let resolveError = try await requireRemoteFileError {
            try await provider.resolveInitialDirectory()
        }
        let listingError = try await requireRemoteFileError {
            try await provider.listDirectory(.root)
        }

        #expect(activeError.category == .cancelled)
        #expect(resolveError.category == .disconnected)
        #expect(listingError.category == .disconnected)
    }

    @Test("The provider accepts 10,000 entries and rejects the next entry before publication")
    func enforcesEntryCountLimitBeforePublication() async throws {
        let root = RemotePath.root
        let entries = try makeEntries(
            count: RemoteDirectoryListing.maximumEntryCount + 1,
            in: root
        )
        let accepted = InMemoryRemoteFileProvider(
            initialDirectory: root,
            directoryGraph: [
                root: .init(entries: Array(entries.dropLast())),
            ]
        )
        let rejected = InMemoryRemoteFileProvider(
            initialDirectory: root,
            directoryGraph: [
                root: .init(entries: entries),
            ]
        )

        let acceptedListing = try await accepted.listDirectory(root)
        let error = try await requireRemoteFileError {
            try await rejected.listDirectory(root)
        }

        #expect(acceptedListing.entries.count == RemoteDirectoryListing.maximumEntryCount)
        #expect(error.category == .limitExceeded)
    }

    @Test("Estimated listing payloads above 32 MiB are rejected before publication")
    func enforcesEstimatedPayloadLimitBeforePublication() async throws {
        let root = RemotePath.root
        let entries = try makeEntries(count: 8_193, in: root, componentByteCount: 4_095)
        let provider = InMemoryRemoteFileProvider(
            initialDirectory: root,
            directoryGraph: [root: .init(entries: entries)]
        )

        let error = try await requireRemoteFileError {
            try await provider.listDirectory(root)
        }

        #expect(InMemoryRemoteFileProvider.maximumEstimatedListingPayloadByteCount == 32 * 1_024 * 1_024)
        #expect(error.category == .limitExceeded)
    }

    @Test("Provider input types enforce component and absolute-path limits")
    func providerInputTypesEnforcePathLimits() throws {
        let maximumComponent = try RemotePathComponent(
            rawBytes: Array(repeating: 0x61, count: RemotePathComponent.maximumRawByteCount)
        )
        let pathSizedComponent = try RemotePathComponent(
            rawBytes: Array(repeating: 0x62, count: 4_095)
        )
        let maximumPath = try RemotePath(components: Array(repeating: pathSizedComponent, count: 8))

        #expect(maximumComponent.rawBytes.count == RemotePathComponent.maximumRawByteCount)
        #expect(maximumPath.rawBytes.count == RemotePath.maximumRawByteCount)

        do {
            _ = try RemotePathComponent(
                rawBytes: Array(repeating: 0x61, count: RemotePathComponent.maximumRawByteCount + 1)
            )
            Issue.record("Expected the oversized component to be rejected")
        } catch let error as RemotePathValidationError {
            #expect(error == .componentTooLong(
                maximum: RemotePathComponent.maximumRawByteCount,
                actual: RemotePathComponent.maximumRawByteCount + 1
            ))
        }

        do {
            let extra = try RemotePathComponent(rawBytes: [0x63])
            _ = try RemotePath(components: maximumPath.components + [extra])
            Issue.record("Expected the oversized path to be rejected")
        } catch let error as RemotePathValidationError {
            #expect(error == .pathTooLong(
                maximum: RemotePath.maximumRawByteCount,
                actual: RemotePath.maximumRawByteCount + 2
            ))
        }
    }

    @Test("The unavailable provider always reports bounded transport guidance and never lists")
    func unavailableProviderNeverFabricatesAListing() async throws {
        let provider = UnavailableRemoteFileProvider()

        let resolveError = try await requireRemoteFileError {
            try await provider.resolveInitialDirectory()
        }
        let listingError = try await requireRemoteFileError {
            try await provider.listDirectory(.root)
        }

        for error in [resolveError, listingError] {
            #expect(error.category == .transportUnavailable)
            #expect(error.userFacingMessage.utf8.count <= RemoteFileError.maximumUserFacingMessageByteCount)
            #expect(error.userFacingMessage.contains("OpenSSH"))
            #expect(error.userFacingMessage.contains("SFTP"))
        }
    }

    private func resolveInitialDirectory(
        using provider: any RemoteFileProvider
    ) async throws -> RemotePath {
        try await provider.resolveInitialDirectory()
    }

    private func delayedProvider() -> InMemoryRemoteFileProvider {
        InMemoryRemoteFileProvider(
            initialDirectory: .root,
            directoryGraph: [.root: .init(entries: [])],
            latency: .seconds(5)
        )
    }

    private func waitForAttempt(
        on provider: InMemoryRemoteFileProvider,
        count: Int = 1
    ) async {
        for _ in 0..<1_000 {
            if await provider.recordedAttempts.count >= count {
                return
            }
            await Task.yield()
        }
        Issue.record("The provider did not record \(count) request attempt(s)")
    }

    private func requireRemoteFileError<Value>(
        _ operation: () async throws -> Value
    ) async throws -> RemoteFileError {
        do {
            _ = try await operation()
            throw ExpectedFailure.missingRemoteFileError
        } catch let error as RemoteFileError {
            return error
        }
    }

    private func remotePath(_ value: String) throws -> RemotePath {
        try RemotePath(rawBytes: Array(value.utf8))
    }

    private func entry(
        _ path: String,
        kind: RemoteFileEntry.Kind = .regular
    ) throws -> RemoteFileEntry {
        try RemoteFileEntry(path: remotePath(path), kind: kind)
    }

    private func makeEntries(
        count: Int,
        in directory: RemotePath,
        componentByteCount: Int? = nil
    ) throws -> [RemoteFileEntry] {
        try (0..<count).map { index in
            var name = Array("item-\(index)-".utf8)
            if let componentByteCount {
                name.append(
                    contentsOf: repeatElement(
                        0x78,
                        count: componentByteCount - name.count
                    )
                )
            }
            let component = try RemotePathComponent(rawBytes: name)
            return try RemoteFileEntry(
                path: directory.appending(component),
                kind: .regular
            )
        }
    }

    private enum ExpectedFailure: Error {
        case missingRemoteFileError
    }
}
