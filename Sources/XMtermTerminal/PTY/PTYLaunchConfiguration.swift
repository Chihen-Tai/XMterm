import Foundation
import XMtermCore

/// Immutable, structured inputs for launching one executable inside a pseudo-terminal.
package struct PTYLaunchConfiguration: Equatable, Sendable {
    /// Absolute path passed to `execve`.
    package let executablePath: String
    /// Optional process name used as `argv[0]`, including login-shell names such as `-zsh`.
    package let argumentZero: String?
    /// Arguments placed after `argv[0]`; these are never interpreted by a shell.
    package let arguments: [String]
    /// Complete environment passed to `execve`.
    package let environment: [String: String]
    /// Absolute directory selected in the child before `execve`.
    package let workingDirectoryPath: String
    /// PTY kernel window size installed before the child starts.
    package let initialSize: TerminalGridSize

    /// Creates structured launch inputs without starting a process.
    package init(
        executablePath: String,
        argumentZero: String? = nil,
        arguments: [String],
        environment: [String: String],
        workingDirectoryPath: String,
        initialSize: TerminalGridSize
    ) {
        self.executablePath = executablePath
        self.argumentZero = argumentZero
        self.arguments = arguments
        self.environment = environment
        self.workingDirectoryPath = workingDirectoryPath
        self.initialSize = initialSize
    }

    func validatedArgumentVector() throws -> [String] {
        guard executablePath.hasPrefix("/") else {
            throw PTYControllerError.executablePathMustBeAbsolute(executablePath)
        }
        guard !executablePath.utf8.contains(0) else {
            throw PTYControllerError.executablePathContainsNUL
        }
        guard workingDirectoryPath.hasPrefix("/") else {
            throw PTYControllerError.workingDirectoryPathMustBeAbsolute(workingDirectoryPath)
        }
        guard !workingDirectoryPath.utf8.contains(0) else {
            throw PTYControllerError.workingDirectoryPathContainsNUL
        }
        if let argumentZero, argumentZero.utf8.contains(0) {
            throw PTYControllerError.argumentZeroContainsNUL
        }
        for (index, argument) in arguments.enumerated() where argument.utf8.contains(0) {
            throw PTYControllerError.argumentContainsNUL(index: index)
        }
        for (key, value) in environment {
            guard !key.isEmpty, !key.contains("="), !key.utf8.contains(0) else {
                throw PTYControllerError.invalidEnvironmentKey(key)
            }
            guard !value.utf8.contains(0) else {
                throw PTYControllerError.environmentValueContainsNUL(key: key)
            }
        }
        try Self.validate(size: initialSize)

        return [argumentZero ?? executablePath] + arguments
    }

    func environmentVector() -> [String] {
        environment.sorted { left, right in
            left.key < right.key
        }.map { entry in
            "\(entry.key)=\(entry.value)"
        }
    }

    static func validate(size: TerminalGridSize) throws {
        guard size.columns > 0, size.rows > 0 else {
            throw PTYControllerError.invalidWindowSize(size)
        }
    }
}

/// Typed PTY boundary failures suitable for deterministic handling without parsing messages.
package enum PTYControllerError: Error, Equatable, Sendable {
    /// The executable path was relative.
    case executablePathMustBeAbsolute(String)
    /// The executable path contained a byte that cannot be represented to `execve`.
    case executablePathContainsNUL
    /// The working-directory path was relative.
    case workingDirectoryPathMustBeAbsolute(String)
    /// The working-directory path contained an embedded NUL.
    case workingDirectoryPathContainsNUL
    /// The explicit `argv[0]` contained an embedded NUL.
    case argumentZeroContainsNUL
    /// An argument contained an embedded NUL.
    case argumentContainsNUL(index: Int)
    /// An environment key was empty or contained `=` or NUL.
    case invalidEnvironmentKey(String)
    /// An environment value contained an embedded NUL.
    case environmentValueContainsNUL(key: String)
    /// Rows or columns could not be represented by the native PTY API.
    case invalidWindowSize(TerminalGridSize)
    /// A read requested a non-positive maximum byte count.
    case invalidReadByteCount(Int)
    /// More than one task attempted to consume the single ordered output stream.
    case readAlreadyInProgress
    /// Queued output exceeded the bounded write budget.
    case pendingWriteLimitExceeded(limit: Int)
    /// Native argument or environment storage could not be allocated.
    case allocationFailed
    /// PTY creation or parent-side descriptor setup failed.
    case ptyCreationFailed(errno: Int32)
    /// The child reported a pre-exec `chdir` or `execve` failure.
    case launchFailed(errno: Int32)
    /// Reading the PTY master failed.
    case readFailed(errno: Int32)
    /// Writing the PTY master failed.
    case writeFailed(errno: Int32)
    /// Updating the PTY kernel window size failed.
    case resizeFailed(errno: Int32)
    /// Reaping or decoding the child wait status failed.
    case waitFailed(errno: Int32)
    /// Signaling the shell or live PTY foreground process group failed.
    case processGroupSignalFailed(signal: Int32, errno: Int32)
    /// The foreground group could no longer be signaled safely through the PTY.
    case foregroundProcessCleanupUnverifiable
    /// A foreground group remained after the final close escalation signal.
    case foregroundProcessGroupStillRunning
    /// The direct child remained live after final signaling and the bounded reap deadline.
    case childProcessStillRunning
    /// The requested operation requires a live, open PTY.
    case closed
}
