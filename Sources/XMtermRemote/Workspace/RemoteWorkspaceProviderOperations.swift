enum RemoteWorkspaceProviderOperations {
  nonisolated static func resolveInitialDirectory(
    using provider: any RemoteFileProvider
  ) async throws -> RemotePath {
    try await provider.resolveInitialDirectory()
  }

  nonisolated static func listDirectory(
    _ directory: RemotePath,
    using provider: any RemoteFileProvider
  ) async throws -> RemoteDirectoryListing {
    try await provider.listDirectory(directory)
  }

  nonisolated static func settleClose(
    provider: any RemoteFileProvider,
    activeTasks: [Task<Void, Never>]
  ) async {
    await provider.cancelAll()
    for task in activeTasks {
      await task.value
    }
    await provider.close()
  }

  static func malformedDirectoryError() -> RemoteFileError {
    RemoteFileError(
      category: .malformedResponse,
      userFacingMessage: "The provider returned a listing for a different directory."
    )
  }

  nonisolated static func remoteFileError(
    from error: any Error
  ) -> RemoteFileError {
    if let remoteError = error as? RemoteFileError {
      return remoteError
    }
    if error is CancellationError {
      return RemoteFileError(category: .cancelled)
    }
    return RemoteFileError(category: .unknown)
  }
}
