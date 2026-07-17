import Foundation
import XMtermCore
@testable import XMtermTerminal

enum ControllableTerminalProcessError: Error, Equatable {
    case launchFailed
    case readFailed
    case writeFailed
    case resizeFailed
}

actor ControllableTerminalProcess: TerminalProcess {
    private var outputChunks: [[UInt8]] = []
    private var outputReachedEOF = false
    private var readWaiter: CheckedContinuation<[UInt8]?, Error>?
    private var exitStatus: TerminalExitStatus?
    private var exitWaiter: CheckedContinuation<TerminalExitStatus, Error>?
    private var nextReadFails = false
    private var nextWriteFails = false
    private var nextResizeFails = false

    private(set) var writes: [[UInt8]] = []
    private(set) var sizes: [TerminalGridSize] = []
    private(set) var closeCount = 0
    private(set) var foregroundQueryCount = 0

    func read(upToCount maximumByteCount: Int) async throws -> [UInt8]? {
        if nextReadFails {
            nextReadFails = false
            throw ControllableTerminalProcessError.readFailed
        }
        if !outputChunks.isEmpty {
            return outputChunks.removeFirst()
        }
        if outputReachedEOF {
            return nil
        }
        return try await withCheckedThrowingContinuation { continuation in
            readWaiter = continuation
        }
    }

    func write(_ bytes: [UInt8]) async throws {
        if nextWriteFails {
            nextWriteFails = false
            throw ControllableTerminalProcessError.writeFailed
        }
        writes = writes + [bytes]
    }

    func resize(to size: TerminalGridSize) async throws {
        if nextResizeFails {
            nextResizeFails = false
            throw ControllableTerminalProcessError.resizeFailed
        }
        sizes = sizes + [size]
    }

    func childExitStatusIfAvailable() async -> TerminalExitStatus? {
        exitStatus
    }

    func waitForExit() async throws -> TerminalExitStatus {
        if let exitStatus {
            return exitStatus
        }
        return try await withCheckedThrowingContinuation { continuation in
            exitWaiter = continuation
        }
    }

    func foregroundProcessGroupState() async -> PTYForegroundProcessGroupState {
        foregroundQueryCount += 1
        return .shell
    }

    func failRead() {
        if let readWaiter {
            self.readWaiter = nil
            readWaiter.resume(throwing: ControllableTerminalProcessError.readFailed)
        } else {
            nextReadFails = true
        }
    }

    func failNextWrite() {
        nextWriteFails = true
    }

    func failNextResize() {
        nextResizeFails = true
    }

    func close(outputPolicy: PTYCloseOutputPolicy) async throws -> TerminalExitStatus {
        closeCount += 1
        let status = exitStatus ?? .signaled(signal: SIGTERM)
        finish(outputChunks: [], status: status)
        return status
    }

    func finish(outputChunks chunks: [[UInt8]], status: TerminalExitStatus) {
        outputChunks = outputChunks + chunks
        outputReachedEOF = true
        exitStatus = status

        if let readWaiter {
            self.readWaiter = nil
            if !outputChunks.isEmpty {
                readWaiter.resume(returning: outputChunks.removeFirst())
            } else {
                readWaiter.resume(returning: nil)
            }
        }
        if let exitWaiter {
            self.exitWaiter = nil
            exitWaiter.resume(returning: status)
        }
    }
}

actor RecordingTerminalProcessLauncher {
    private(set) var configurations: [PTYLaunchConfiguration] = []
    let process: ControllableTerminalProcess
    var error: ControllableTerminalProcessError?

    init(
        process: ControllableTerminalProcess = ControllableTerminalProcess(),
        error: ControllableTerminalProcessError? = nil
    ) {
        self.process = process
        self.error = error
    }

    func launch(_ configuration: PTYLaunchConfiguration) async throws -> any TerminalProcess {
        configurations = configurations + [configuration]
        if let error {
            throw error
        }
        return process
    }
}

actor DelayedTerminalProcessLauncher {
    let process: ControllableTerminalProcess
    private var launchContinuation: CheckedContinuation<any TerminalProcess, Never>?
    private(set) var didReceiveLaunch = false
    private var releaseWasRequested = false

    init(process: ControllableTerminalProcess = ControllableTerminalProcess()) {
        self.process = process
    }

    func launch(_ configuration: PTYLaunchConfiguration) async -> any TerminalProcess {
        didReceiveLaunch = true
        if releaseWasRequested {
            return process
        }
        return await withCheckedContinuation { continuation in
            launchContinuation = continuation
        }
    }

    func release() {
        guard let launchContinuation else {
            releaseWasRequested = true
            return
        }
        self.launchContinuation = nil
        launchContinuation.resume(returning: process)
    }
}
