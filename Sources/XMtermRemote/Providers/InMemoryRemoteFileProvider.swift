public actor InMemoryRemoteFileProvider: RemoteFileProvider {
    public static let maximumEstimatedListingPayloadByteCount = 32 * 1_024 * 1_024

    public struct Directory: Equatable, Sendable {
        public let entries: [RemoteFileEntry]
        public let metadataCompleteness: RemoteMetadataCompleteness
        public let providerCapabilityNotes: String?

        public init(
            entries: [RemoteFileEntry],
            metadataCompleteness: RemoteMetadataCompleteness = .partial,
            providerCapabilityNotes: String? = nil
        ) {
            self.entries = entries
            self.metadataCompleteness = metadataCompleteness
            self.providerCapabilityNotes = providerCapabilityNotes
        }
    }

    public enum Response<Value: Sendable>: Sendable {
        case success(Value)
        case failure(RemoteFileError)
    }

    public struct DeterministicResponses: Sendable {
        public let initialDirectory: Response<RemotePath>?
        public let listings: [RemotePath: Response<Directory>]

        public init(
            initialDirectory: Response<RemotePath>? = nil,
            listings: [RemotePath: Response<Directory>] = [:]
        ) {
            self.initialDirectory = initialDirectory
            self.listings = listings
        }
    }

    public enum AttemptKind: Equatable, Sendable {
        case resolveInitialDirectory
        case listDirectory
    }

    public var recordedAttempts: [AttemptKind] {
        storedAttempts
    }

    private let initialDirectory: RemotePath
    private let directoryGraph: [RemotePath: Directory]
    private let deterministicResponses: DeterministicResponses
    private let latency: Duration

    private var storedAttempts: [AttemptKind] = []
    private var requestTasks: [UInt64: Task<Void, Error>] = [:]
    private var nextRequestIdentifier: UInt64 = 0
    private var cancellationGeneration: UInt64 = 0
    private var isClosed = false

    public init(
        initialDirectory: RemotePath,
        directoryGraph: [RemotePath: Directory],
        deterministicResponses: DeterministicResponses = .init(),
        latency: Duration = .zero
    ) {
        self.initialDirectory = initialDirectory
        self.directoryGraph = directoryGraph
        self.deterministicResponses = deterministicResponses
        self.latency = latency > .zero ? latency : .zero
    }

    public func resolveInitialDirectory() async throws -> RemotePath {
        storedAttempts.append(.resolveInitialDirectory)
        try rejectClosedProvider()
        try await waitForConfiguredLatency()

        switch deterministicResponses.initialDirectory {
        case let .success(path):
            return path
        case let .failure(error):
            throw error
        case nil:
            return initialDirectory
        }
    }

    public func listDirectory(_ path: RemotePath) async throws -> RemoteDirectoryListing {
        storedAttempts.append(.listDirectory)
        try rejectClosedProvider()
        try await waitForConfiguredLatency()

        let directory: Directory
        if let response = deterministicResponses.listings[path] {
            switch response {
            case let .success(value):
                directory = value
            case let .failure(error):
                throw error
            }
        } else if let value = directoryGraph[path] {
            directory = value
        } else {
            throw RemoteFileError(category: .pathNotFound)
        }

        return try validatedListing(directory, for: path)
    }

    public func cancelAll() async {
        cancelActiveRequests()
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        cancelActiveRequests()
    }

    private func rejectClosedProvider() throws {
        guard !isClosed else {
            throw RemoteFileError(
                category: .disconnected,
                userFacingMessage: "The remote file provider is closed."
            )
        }
    }

    private func waitForConfiguredLatency() async throws {
        do {
            try Task.checkCancellation()
        } catch {
            throw cancellationError()
        }
        guard latency > .zero else { return }

        let requestIdentifier = nextRequestIdentifier
        nextRequestIdentifier &+= 1
        let requestGeneration = cancellationGeneration
        let delay = latency
        let requestTask = Task<Void, Error> {
            try await Task.sleep(for: delay)
        }
        requestTasks[requestIdentifier] = requestTask
        defer {
            requestTasks[requestIdentifier] = nil
        }

        do {
            try await withTaskCancellationHandler {
                try await requestTask.value
            } onCancel: {
                requestTask.cancel()
            }
        } catch {
            throw cancellationError()
        }

        guard !Task.isCancelled,
              requestGeneration == cancellationGeneration,
              !isClosed else {
            throw cancellationError()
        }
    }

    private func cancelActiveRequests() {
        cancellationGeneration &+= 1
        for requestTask in requestTasks.values {
            requestTask.cancel()
        }
    }

    private func validatedListing(
        _ directory: Directory,
        for path: RemotePath
    ) throws -> RemoteDirectoryListing {
        guard directory.entries.count <= RemoteDirectoryListing.maximumEntryCount else {
            throw limitExceededError()
        }
        guard estimatedPayloadByteCount(for: directory, at: path)
                <= Self.maximumEstimatedListingPayloadByteCount else {
            throw limitExceededError()
        }

        do {
            return try RemoteDirectoryListing(
                directory: path,
                entries: directory.entries,
                metadataCompleteness: directory.metadataCompleteness,
                providerCapabilityNotes: directory.providerCapabilityNotes
            )
        } catch let error as RemoteDirectoryListingValidationError {
            switch error {
            case .tooManyEntries, .capabilityNotesTooLong:
                throw limitExceededError()
            case .entryOutsideDirectory, .duplicateEntry:
                throw RemoteFileError(
                    category: .malformedResponse,
                    userFacingMessage: "The provider returned an invalid directory listing."
                )
            }
        } catch {
            throw RemoteFileError(category: .providerFailure)
        }
    }

    private func estimatedPayloadByteCount(
        for directory: Directory,
        at path: RemotePath
    ) -> Int {
        var total = path.rawBytes.count
        if let notes = directory.providerCapabilityNotes {
            total = adding(notes.utf8.count, to: total)
        }

        for entry in directory.entries {
            total = adding(entry.path.rawBytes.count, to: total)
            total = adding(entry.name.rawBytes.count, to: total)
            total = adding(estimatedMetadataByteCount(for: entry), to: total)
            if let target = entry.symbolicLinkTarget {
                total = adding(target.rawBytes.count, to: total)
            }
            if total > Self.maximumEstimatedListingPayloadByteCount {
                return total
            }
        }
        return total
    }

    private func estimatedMetadataByteCount(for entry: RemoteFileEntry) -> Int {
        1
            + (entry.size == nil ? 0 : MemoryLayout<UInt64>.size)
            + (entry.modificationDate == nil ? 0 : MemoryLayout<Double>.size)
            + (entry.permissions == nil ? 0 : MemoryLayout<UInt16>.size)
    }

    private func adding(_ value: Int, to total: Int) -> Int {
        let (result, overflow) = total.addingReportingOverflow(value)
        return overflow ? Int.max : result
    }

    private func limitExceededError() -> RemoteFileError {
        RemoteFileError(
            category: .limitExceeded,
            userFacingMessage: "The directory listing exceeded a provider safety limit."
        )
    }

    private func cancellationError() -> RemoteFileError {
        RemoteFileError(category: .cancelled)
    }
}
