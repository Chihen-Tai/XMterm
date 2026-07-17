package enum TerminalTabKind: Equatable, Sendable {
    case local
    case relaySSH
}

package enum SSHProcessState: Equatable, Sendable {
    case idle
    case starting
    case processRunning
    case closing
    case exited(TerminalExitStatus)
    case failed(TerminalFailure)

    package init(lifecycle: TerminalLifecycle) {
        switch lifecycle {
        case .idle:
            self = .idle
        case .starting:
            self = .starting
        case .running:
            self = .processRunning
        case .closing:
            self = .closing
        case let .exited(status):
            self = .exited(status)
        case let .failed(failure):
            self = .failed(failure)
        }
    }
}
