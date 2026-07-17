import Testing

@testable import XMtermRemote

@Suite("Remote workspace close settlement")
@MainActor
struct RemoteWorkspaceCloseSettlementTests {
  @Test("[FILE-WORKSPACE-001] Close waits for an explicitly cancelled initial request to unwind")
  func closeRetainsCancelledInitialTaskUntilItSettles() async {
    let provider = LaggingCancellationRemoteFileProvider()
    let workspace = RemoteWorkspace(provider: provider)

    workspace.start()
    await eventually { await provider.didEnterResolve }
    workspace.cancelCurrentRequest()

    let closeTask = Task { @MainActor in
      await workspace.close()
    }
    await eventually { await provider.didBeginUnwind }

    #expect(workspace.availability == .closing)
    #expect(await provider.closeCount == 0)

    await provider.releaseUnwind()
    await closeTask.value

    #expect(await provider.didFinishUnwind)
    #expect(await provider.closeCount == 1)
    #expect(workspace.availability == .closed)
  }

  private func eventually(
    _ condition: @escaping @MainActor () async -> Bool
  ) async {
    for _ in 0..<10_000 {
      if await condition() { return }
      await Task.yield()
    }
    Issue.record("Timed out waiting for deterministic close state")
  }
}

private actor LaggingCancellationRemoteFileProvider: RemoteFileProvider {
  private var request: CheckedContinuation<RemotePath, Error>?
  private var unwind: CheckedContinuation<Void, Never>?

  private(set) var didEnterResolve = false
  private(set) var didBeginUnwind = false
  private(set) var didFinishUnwind = false
  private(set) var closeCount = 0

  func resolveInitialDirectory() async throws -> RemotePath {
    didEnterResolve = true
    do {
      return try await withCheckedThrowingContinuation { continuation in
        request = continuation
      }
    } catch {
      didBeginUnwind = true
      await withCheckedContinuation { continuation in
        unwind = continuation
      }
      didFinishUnwind = true
      throw error
    }
  }

  func listDirectory(_ path: RemotePath) async throws -> RemoteDirectoryListing {
    throw RemoteFileError(category: .providerFailure)
  }

  func cancelAll() async {
    let continuation = request
    request = nil
    continuation?.resume(
      throwing: RemoteFileError(category: .cancelled)
    )
  }

  func close() async {
    closeCount += 1
  }

  func releaseUnwind() {
    let continuation = unwind
    unwind = nil
    continuation?.resume()
  }
}
