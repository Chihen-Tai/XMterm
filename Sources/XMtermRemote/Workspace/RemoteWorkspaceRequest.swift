struct RemoteWorkspaceNavigationPlan {
  let destination: RemoteWorkspaceLocation
  let backHistory: [RemoteWorkspaceLocation]
  let forwardHistory: [RemoteWorkspaceLocation]
}

enum RemoteWorkspaceRequestPurpose {
  case navigation(RemoteWorkspaceNavigationPlan)
  case refresh(selectedEntry: RemotePath?)
  case expansion
}

struct RemoteWorkspaceDirectoryRequest {
  let path: RemotePath
  let generation: UInt64
  let purpose: RemoteWorkspaceRequestPurpose
  let previousListing: RemoteDirectoryListing?
}

struct RemoteWorkspaceActiveRequest {
  let request: RemoteWorkspaceDirectoryRequest
  let task: Task<Void, Never>
}
