import Darwin
import XMtermCore
import XMtermTerminal

enum WorkspaceTestProcessError: Error, Sendable {
    case launchFailed
}

actor WorkspaceTestTerminalProcess: TerminalProcess {
    private var reachedEOF = false
    private var readContinuation: CheckedContinuation<[UInt8]?, Error>?
    private var exitStatus: TerminalExitStatus?
    private var exitContinuation: CheckedContinuation<TerminalExitStatus, Error>?

    func read(upToCount maximumByteCount: Int) async throws -> [UInt8]? {
        if reachedEOF { return nil }
        return try await withCheckedThrowingContinuation { continuation in
            readContinuation = continuation
        }
    }

    func write(_ bytes: [UInt8]) async throws {}

    func resize(to size: TerminalGridSize) async throws {}

    func childExitStatusIfAvailable() async -> TerminalExitStatus? {
        exitStatus
    }

    func waitForExit() async throws -> TerminalExitStatus {
        if let exitStatus { return exitStatus }
        return try await withCheckedThrowingContinuation { continuation in
            exitContinuation = continuation
        }
    }

    func foregroundProcessGroupState() async -> PTYForegroundProcessGroupState {
        .shell
    }

    func close(outputPolicy: PTYCloseOutputPolicy) async throws -> TerminalExitStatus {
        let status = exitStatus ?? .signaled(signal: SIGTERM)
        finish(status: status)
        return status
    }

    func finish(status: TerminalExitStatus) {
        reachedEOF = true
        exitStatus = status
        let pendingRead = readContinuation
        readContinuation = nil
        pendingRead?.resume(returning: nil)
        let pendingExit = exitContinuation
        exitContinuation = nil
        pendingExit?.resume(returning: status)
    }
}
