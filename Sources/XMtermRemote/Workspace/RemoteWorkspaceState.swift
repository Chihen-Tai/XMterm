import Foundation

public struct RemoteWorkspaceID: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct RemoteScrollRestorationToken: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct RemoteWorkspaceLocation: Equatable, Sendable {
    public let directory: RemotePath
    public let selectedEntry: RemotePath?
    public let scrollRestorationToken: RemoteScrollRestorationToken?

    public init(
        directory: RemotePath,
        selectedEntry: RemotePath?,
        scrollRestorationToken: RemoteScrollRestorationToken?
    ) {
        self.directory = directory
        self.selectedEntry = selectedEntry
        self.scrollRestorationToken = scrollRestorationToken
    }
}

public enum RemoteWorkspaceAvailability: Equatable, Sendable {
    case idle
    case connecting
    case loadingInitialDirectory
    case available
    case failed(RemoteFileError)
    case closing
    case closed
}

public enum RemoteDirectoryLoadState: Equatable, Sendable {
    case notLoaded
    case loading(previousListing: RemoteDirectoryListing?)
    case loaded(RemoteDirectoryListing)
    case empty(RemoteDirectoryListing)
    case failed(
        error: RemoteFileError,
        previousListing: RemoteDirectoryListing?
    )
    case cancelled(previousListing: RemoteDirectoryListing?)

    public var visibleListing: RemoteDirectoryListing? {
        switch self {
        case .notLoaded:
            nil
        case let .loading(previousListing):
            previousListing
        case let .loaded(listing), let .empty(listing):
            listing
        case let .failed(_, previousListing), let .cancelled(previousListing):
            previousListing
        }
    }

    public var isRefreshing: Bool {
        if case .loading(previousListing: .some) = self {
            return true
        }
        return false
    }
}
