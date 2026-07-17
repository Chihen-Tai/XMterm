import XMtermCore

/// Narrow process boundary shared by local shells and direct OpenSSH sessions.
///
/// Production uses `PTYProcessController`; tests can supply deterministic process actors without
/// weakening the native PTY ownership boundary.
package protocol TerminalProcess: Sendable {
    func read(upToCount maximumByteCount: Int) async throws -> [UInt8]?
    func write(_ bytes: [UInt8]) async throws
    func resize(to size: TerminalGridSize) async throws
    /// Returns the direct child's status without waiting for final PTY EOF, when already known.
    func childExitStatusIfAvailable() async -> TerminalExitStatus?
    func waitForExit() async throws -> TerminalExitStatus
    func foregroundProcessGroupState() async -> PTYForegroundProcessGroupState
    func close(outputPolicy: PTYCloseOutputPolicy) async throws -> TerminalExitStatus
}

package typealias TerminalProcessLauncher = @Sendable (
    PTYLaunchConfiguration
) async throws -> any TerminalProcess
