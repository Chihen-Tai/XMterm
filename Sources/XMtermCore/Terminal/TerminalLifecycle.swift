package enum TerminalExitStatus: Equatable, Sendable {
    case exited(code: Int32)
    case signaled(signal: Int32)

    public init(decodingDarwinWaitStatus status: Int32) throws {
        let lowSevenBits = status & 0x7F

        if lowSevenBits == 0x7F {
            let stopSignal = (status >> 8) & 0xFF
            if stopSignal == 0x13 {
                throw TerminalWaitStatusDecodingError.processContinued
            }
            throw TerminalWaitStatusDecodingError.processStopped(signal: stopSignal)
        }

        if lowSevenBits == 0 {
            self = .exited(code: (status >> 8) & 0xFF)
        } else {
            self = .signaled(signal: lowSevenBits)
        }
    }

    public var summary: String {
        switch self {
        case .exited(code: 0):
            "Exited normally"
        case let .exited(code):
            "Exited with status \(code)"
        case let .signaled(signal):
            "Terminated by signal \(signal)"
        }
    }
}

package enum TerminalWaitStatusDecodingError: Error, Equatable, Sendable {
    case processStopped(signal: Int32)
    case processContinued
}

package enum TerminalFailure: Error, Equatable, Sendable {
    case ptyCreation(message: String)
    case launch(message: String)
    case read(message: String)
    case write(message: String)
    case resize(message: String)

    public var userFacingMessage: String {
        switch self {
        case .ptyCreation:
            "XMterm could not create a local terminal."
        case .launch:
            "XMterm could not start the local shell."
        case .read:
            "XMterm lost the terminal output stream."
        case .write:
            "XMterm could not send input to the local shell."
        case .resize:
            "XMterm could not resize the local terminal."
        }
    }

    public var requiresProcessCleanup: Bool {
        switch self {
        case .ptyCreation, .launch:
            false
        case .read, .write, .resize:
            true
        }
    }
}

package enum TerminalLifecycle: Equatable, Sendable {
    case idle
    case starting
    case running
    case closing
    case exited(TerminalExitStatus)
    case failed(TerminalFailure)

    public func transitioned(by event: TerminalLifecycleEvent) throws -> Self {
        switch (self, event) {
        case (.idle, .startRequested):
            .starting
        case (.starting, .launchSucceeded):
            .running
        case let (.starting, .ptyCreationFailed(message)):
            .failed(.ptyCreation(message: message))
        case let (.starting, .launchFailed(message)):
            .failed(.launch(message: message))
        case (.idle, .closeRequested),
             (.starting, .closeRequested),
             (.running, .closeRequested):
            .closing
        case let (.starting, .processExited(status)),
             let (.running, .processExited(status)),
             let (.closing, .processExited(status)):
            .exited(status)
        case let (.running, .readFailed(message)):
            .failed(.read(message: message))
        case let (.running, .writeFailed(message)):
            .failed(.write(message: message))
        case let (.running, .resizeFailed(message)):
            .failed(.resize(message: message))
        case let (.failed(failure), .processExited):
            .failed(failure)
        default:
            throw TerminalLifecycleTransitionError.invalidTransition(from: self, event: event)
        }
    }

    public var acceptsInput: Bool {
        self == .running
    }

}

package enum TerminalLifecycleEvent: Equatable, Sendable {
    case startRequested
    case launchSucceeded
    case ptyCreationFailed(String)
    case launchFailed(String)
    case closeRequested
    case processExited(TerminalExitStatus)
    case readFailed(String)
    case writeFailed(String)
    case resizeFailed(String)
}

package enum TerminalLifecycleTransitionError: Error, Equatable, Sendable {
    case invalidTransition(from: TerminalLifecycle, event: TerminalLifecycleEvent)
}
