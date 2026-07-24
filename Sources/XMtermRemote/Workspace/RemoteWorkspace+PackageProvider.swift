import XMtermCore

@MainActor
extension RemoteWorkspace {
  /// Package-only construction seam for deterministic providers and the future
  /// reviewed transport composition. Public clients stay fail-closed until a
  /// concrete production transport type exists.
  package convenience init(
    id: RemoteWorkspaceID = RemoteWorkspaceID(),
    runtimeID: TerminalSessionID = TerminalSessionID(),
    provider: any RemoteFileProvider,
    directoryCache: RemoteDirectoryCache = RemoteDirectoryCache()
  ) {
    self.init(
      id: id,
      composition: .packageTest(
        provider,
        owner: RemoteTransferOwnerIdentity(
          runtimeID: runtimeID,
          workspaceID: id
        )
      ),
      directoryCache: directoryCache
    )
  }
}
