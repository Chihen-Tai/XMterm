import Foundation

/// Clipboard metadata shown to the user without exposing clipboard content in UI state.
package struct TerminalPastePrompt: Identifiable, Equatable {
    package let id: UUID
    package let byteCount: Int
    package let lineCount: Int
    package let containsControlCharacters: Bool

    init(
        id: UUID = UUID(),
        byteCount: Int,
        lineCount: Int,
        containsControlCharacters: Bool
    ) {
        self.id = id
        self.byteCount = byteCount
        self.lineCount = lineCount
        self.containsControlCharacters = containsControlCharacters
    }
}

package struct TerminalSessionErrorAlert: Identifiable, Equatable {
    package let id: UUID
    package let message: String

    init(id: UUID = UUID(), message: String) {
        self.id = id
        self.message = message
    }
}

package enum TerminalSessionAlert: Identifiable, Equatable {
    case paste(TerminalPastePrompt)
    case error(TerminalSessionErrorAlert)

    package var id: UUID {
        switch self {
        case let .paste(prompt): prompt.id
        case let .error(alert): alert.id
        }
    }
}
