package struct TerminalInputModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let command = Self(rawValue: 1 << 0)
    public static let control = Self(rawValue: 1 << 1)
    public static let option = Self(rawValue: 1 << 2)
    public static let shift = Self(rawValue: 1 << 3)
}

package enum TerminalInputKey: Equatable, Sendable {
    case character(Character)
    case special
}

package enum TerminalLocalAction: Equatable, Sendable {
    case copy
    case paste
    case closeTab
    case find
    case newTab
    case selectAll
    case unhandledCommand
}

package enum TerminalInputRoute: Equatable, Sendable {
    case ptyBytes([UInt8])
    case local(TerminalLocalAction)
    case engine
}

package enum TerminalInputRouter {
    public static func route(
        key: TerminalInputKey,
        modifiers: TerminalInputModifiers
    ) -> TerminalInputRoute {
        if modifiers.contains(.command) {
            return modifiers == [.command]
                ? .local(localAction(for: key))
                : .local(.unhandledCommand)
        }

        guard modifiers.contains(.control),
              case let .character(character) = key,
              let controlByte = controlByte(for: character) else {
            return .engine
        }
        return .ptyBytes([controlByte])
    }

    private static func localAction(for key: TerminalInputKey) -> TerminalLocalAction {
        guard case let .character(character) = key else { return .unhandledCommand }
        return switch String(character).uppercased() {
        case "C": .copy
        case "V": .paste
        case "W": .closeTab
        case "F": .find
        case "T": .newTab
        case "A": .selectAll
        default: .unhandledCommand
        }
    }

    private static func controlByte(for character: Character) -> UInt8? {
        let value = String(character).uppercased()
        guard let scalar = value.unicodeScalars.first, value.unicodeScalars.count == 1 else {
            return nil
        }

        return switch scalar.value {
        case 0x00...0x1F:
            UInt8(scalar.value)
        case 0x40...0x5F:
            UInt8(scalar.value - 0x40)
        case 0x20:
            0x00
        case 0x3F, 0x7F:
            0x7F
        default:
            nil
        }
    }
}
