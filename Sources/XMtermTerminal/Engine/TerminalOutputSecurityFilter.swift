import Foundation

/// A streaming safety boundary for untrusted terminal output.
///
/// SwiftTerm remains responsible for emulation. This filter only enforces Phase 1's deliberately
/// smaller protocol surface before bytes reach the engine: ordinary text, C0 controls, escape
/// commands, and bounded CSI commands are allowed; host-action and graphics-bearing control
/// strings are discarded. It buffers at most one small CSI or ESC sequence and never stores a
/// control-string payload.
package struct TerminalOutputSecurityFilter: Sendable {
    package static let maximumBufferedBytes = 128
    private static let maximumParameterDigits = 9
    private static let maximumParameterSeparators = 32
    private static let maximumParameterValue = 2_048

    private enum ControlStringKind: Sendable {
        case osc
        case dcs
        case apc
        case privacyMessage
        case startOfString
    }

    private enum State: Sendable {
        case ground
        case escape(buffer: [UInt8])
        case csi(
            buffer: [UInt8],
            currentDigitCount: Int,
            separatorCount: Int,
            sawIntermediate: Bool
        )
        case controlString(kind: ControlStringKind, escapePending: Bool)
        case discardCSI
        case discardEscape
    }

    private struct CSIParameter {
        let value: Int
        let separatorAfter: UInt8?
    }

    private var state: State = .ground
    private var utf8ContinuationCount = 0

    package init() {}

    package var bufferedByteCount: Int {
        switch state {
        case let .escape(buffer), let .csi(buffer, _, _, _):
            buffer.count
        case .ground, .controlString, .discardCSI, .discardEscape:
            0
        }
    }

    package var isDiscardingControlString: Bool {
        if case .controlString = state { return true }
        return false
    }

    package mutating func process(_ bytes: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        for byte in bytes {
            process(byte, into: &output)
        }
        return output
    }

    private mutating func process(_ byte: UInt8, into output: inout [UInt8]) {
        switch state {
        case .ground:
            processGround(byte, into: &output)
        case let .escape(buffer):
            processEscape(byte, buffer: buffer, into: &output)
        case let .csi(buffer, digitCount, separatorCount, sawIntermediate):
            processCSI(
                byte,
                buffer: buffer,
                digitCount: digitCount,
                separatorCount: separatorCount,
                sawIntermediate: sawIntermediate,
                into: &output
            )
        case let .controlString(kind, escapePending):
            processControlString(byte, kind: kind, escapePending: escapePending)
        case .discardCSI:
            processDiscardedCSI(byte)
        case .discardEscape:
            processDiscardedEscape(byte)
        }
    }

    private mutating func processGround(_ byte: UInt8, into output: inout [UInt8]) {
        if utf8ContinuationCount > 0 {
            guard (0x80...0xBF).contains(byte) else {
                utf8ContinuationCount = 0
                processGround(byte, into: &output)
                return
            }
            utf8ContinuationCount -= 1
            output.append(byte)
            return
        }

        switch byte {
        case 0x1B:
            state = .escape(buffer: [byte])
        case 0x90:
            state = .controlString(kind: .dcs, escapePending: false)
        case 0x98:
            state = .controlString(kind: .startOfString, escapePending: false)
        case 0x9B:
            state = initialCSIState(start: byte)
        case 0x9D:
            state = .controlString(kind: .osc, escapePending: false)
        case 0x9E:
            state = .controlString(kind: .privacyMessage, escapePending: false)
        case 0x9F:
            state = .controlString(kind: .apc, escapePending: false)
        case 0x9C:
            break
        case 0xC2...0xDF:
            utf8ContinuationCount = 1
            output.append(byte)
        case 0xE0...0xEF:
            utf8ContinuationCount = 2
            output.append(byte)
        case 0xF0...0xF4:
            utf8ContinuationCount = 3
            output.append(byte)
        default:
            output.append(byte)
        }
    }

    private mutating func processEscape(
        _ byte: UInt8,
        buffer: [UInt8],
        into output: inout [UInt8]
    ) {
        if buffer.count == 1 {
            switch byte {
            case 0x1B:
                state = .escape(buffer: [byte])
                return
            case 0x5B:
                state = initialCSIState(start: buffer[0], second: byte)
                return
            case 0x5D:
                state = .controlString(kind: .osc, escapePending: false)
                return
            case 0x50:
                state = .controlString(kind: .dcs, escapePending: false)
                return
            case 0x5F:
                state = .controlString(kind: .apc, escapePending: false)
                return
            case 0x5E:
                state = .controlString(kind: .privacyMessage, escapePending: false)
                return
            case 0x58:
                state = .controlString(kind: .startOfString, escapePending: false)
                return
            case 0x18, 0x1A:
                state = .ground
                return
            default:
                break
            }
        }

        if (0x30...0x7E).contains(byte) {
            output.append(contentsOf: buffer)
            output.append(byte)
            state = .ground
        } else if (0x20...0x2F).contains(byte),
                  buffer.count < Self.maximumBufferedBytes - 1 {
            state = .escape(buffer: buffer + [byte])
        } else {
            state = .discardEscape
        }
    }

    private mutating func processCSI(
        _ byte: UInt8,
        buffer: [UInt8],
        digitCount: Int,
        separatorCount: Int,
        sawIntermediate: Bool,
        into output: inout [UInt8]
    ) {
        if byte == 0x1B {
            state = .escape(buffer: [byte])
            return
        }
        if byte == 0x18 || byte == 0x1A {
            state = .ground
            return
        }
        if (0x40...0x7E).contains(byte) {
            guard buffer.count < Self.maximumBufferedBytes,
                  shouldForwardCSI(buffer: buffer, finalByte: byte) else {
                state = .ground
                return
            }
            output.append(contentsOf: buffer)
            output.append(byte)
            state = .ground
            return
        }

        guard buffer.count < Self.maximumBufferedBytes - 1 else {
            state = .discardCSI
            return
        }

        if (0x30...0x39).contains(byte) {
            guard !sawIntermediate, digitCount < Self.maximumParameterDigits else {
                state = .discardCSI
                return
            }
            state = .csi(
                buffer: buffer + [byte],
                currentDigitCount: digitCount + 1,
                separatorCount: separatorCount,
                sawIntermediate: false
            )
        } else if byte == 0x3B || byte == 0x3A {
            guard !sawIntermediate,
                  separatorCount < Self.maximumParameterSeparators else {
                state = .discardCSI
                return
            }
            state = .csi(
                buffer: buffer + [byte],
                currentDigitCount: 0,
                separatorCount: separatorCount + 1,
                sawIntermediate: false
            )
        } else if (0x3C...0x3F).contains(byte) {
            guard !sawIntermediate, digitCount == 0 else {
                state = .discardCSI
                return
            }
            state = .csi(
                buffer: buffer + [byte],
                currentDigitCount: 0,
                separatorCount: separatorCount,
                sawIntermediate: false
            )
        } else if (0x20...0x2F).contains(byte) {
            state = .csi(
                buffer: buffer + [byte],
                currentDigitCount: 0,
                separatorCount: separatorCount,
                sawIntermediate: true
            )
        } else {
            state = .discardCSI
        }
    }

    private mutating func processControlString(
        _ byte: UInt8,
        kind: ControlStringKind,
        escapePending: Bool
    ) {
        if byte == 0x18 || byte == 0x1A || byte == 0x9C {
            state = .ground
            return
        }
        if escapePending {
            if byte == 0x5C {
                state = .ground
            } else {
                state = .controlString(kind: kind, escapePending: byte == 0x1B)
            }
            return
        }
        if kind == .osc, byte == 0x07 {
            state = .ground
        } else {
            state = .controlString(kind: kind, escapePending: byte == 0x1B)
        }
    }

    private mutating func processDiscardedCSI(_ byte: UInt8) {
        if byte == 0x1B {
            state = .escape(buffer: [byte])
        } else if byte == 0x18 || byte == 0x1A || (0x40...0x7E).contains(byte) {
            state = .ground
        }
    }

    private mutating func processDiscardedEscape(_ byte: UInt8) {
        if byte == 0x1B {
            state = .escape(buffer: [byte])
        } else if byte == 0x18 || byte == 0x1A || (0x30...0x7E).contains(byte) {
            state = .ground
        }
    }

    private func initialCSIState(start: UInt8, second: UInt8? = nil) -> State {
        .csi(
            buffer: second.map { [start, $0] } ?? [start],
            currentDigitCount: 0,
            separatorCount: 0,
            sawIntermediate: false
        )
    }

    private func shouldForwardCSI(buffer: [UInt8], finalByte: UInt8) -> Bool {
        // CSI ... t performs xterm window and title-stack operations. Those host-facing commands
        // are outside Phase 1, and SwiftTerm's title stacks are unbounded.
        guard finalByte != 0x74 else { return false }

        // SwiftTerm prints SGR-pixel mouse coordinates unconditionally when private mode 1016 is
        // enabled. Keep terminal-controlled pointer data out of process diagnostics until the
        // pinned engine honors silent logging for that path.
        if finalByte == 0x68 || finalByte == 0x6C,
           let parsed = parseCSIParameters(buffer),
           parsed.hasPrivateMarker,
           parsed.parameters.contains(where: { $0.value == 1_016 }) {
            return false
        }

        // SwiftTerm contains unconditional print paths for unknown SGR attributes and DEC
        // locator commands. Keep terminal-controlled values out of process diagnostics.
        if finalByte == 0x7A, buffer.contains(0x27) { return false }
        if finalByte == 0x6D, !isSafeSGR(buffer: buffer) { return false }

        var parameterValue = 0
        var hasParameterDigits = false
        for byte in buffer {
            if (0x30...0x39).contains(byte) {
                hasParameterDigits = true
                parameterValue = parameterValue * 10 + Int(byte - 0x30)
                guard parameterValue <= Self.maximumParameterValue else { return false }
            } else if hasParameterDigits {
                parameterValue = 0
                hasParameterDigits = false
            }
        }
        return true
    }

    private func isSafeSGR(buffer: [UInt8]) -> Bool {
        guard let parsed = parseCSIParameters(buffer) else { return false }
        if parsed.hasPrivateMarker { return true }

        let parameters = parsed.parameters
        var index = 0
        while index < parameters.count {
            let parameter = parameters[index]

            if parameter.value == 4, parameter.separatorAfter == 0x3A {
                guard index + 1 < parameters.count else { return false }
                index += 2
                continue
            }

            if parameter.value == 38 || parameter.value == 48 || parameter.value == 58 {
                guard index + 1 < parameters.count else { return false }
                let colorMode = parameters[index + 1].value
                if parameter.separatorAfter == 0x3A {
                    var end = index + 1
                    while end < parameters.count - 1,
                          parameters[end].separatorAfter == 0x3A {
                        end += 1
                    }
                    let groupCount = end - index + 1
                    guard (colorMode == 2 && groupCount >= 5)
                            || (colorMode == 5 && groupCount >= 3) else {
                        return false
                    }
                    index = end + 1
                    continue
                }

                if colorMode == 2 {
                    guard index + 4 < parameters.count else { return false }
                    index += 5
                    continue
                }
                if colorMode == 5 {
                    guard index + 2 < parameters.count else { return false }
                    index += 3
                    continue
                }
                return false
            }

            guard isKnownSGRAttribute(parameter.value) else { return false }
            index += 1
        }
        return true
    }

    private func parseCSIParameters(
        _ buffer: [UInt8]
    ) -> (parameters: [CSIParameter], hasPrivateMarker: Bool)? {
        let prefixCount = buffer.first == 0x1B ? 2 : 1
        guard buffer.count >= prefixCount else { return nil }

        var parameters: [CSIParameter] = []
        var currentValue = 0
        var hasDigits = false
        var hasPrivateMarker = false

        for byte in buffer.dropFirst(prefixCount) {
            if (0x30...0x39).contains(byte) {
                hasDigits = true
                currentValue = currentValue * 10 + Int(byte - 0x30)
            } else if byte == 0x3B || byte == 0x3A {
                parameters.append(
                    CSIParameter(value: hasDigits ? currentValue : 0, separatorAfter: byte)
                )
                currentValue = 0
                hasDigits = false
            } else if (0x3C...0x3F).contains(byte) {
                guard !hasDigits else { return nil }
                hasPrivateMarker = true
            } else if (0x20...0x2F).contains(byte) {
                break
            } else {
                return nil
            }
        }
        parameters.append(
            CSIParameter(value: hasDigits ? currentValue : 0, separatorAfter: nil)
        )
        return (parameters, hasPrivateMarker)
    }

    private func isKnownSGRAttribute(_ value: Int) -> Bool {
        switch value {
        case 0...5, 7...9, 21...25, 27...49, 59, 90...97, 100...107:
            true
        default:
            false
        }
    }
}
