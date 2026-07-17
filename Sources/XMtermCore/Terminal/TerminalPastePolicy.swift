package struct TerminalPastePayload: Equatable, Sendable {
    public let normalizedText: String
    public let isMultiline: Bool
    public let requiresConfirmation: Bool
    public let bytes: [UInt8]

    package init(
        normalizedText: String,
        isMultiline: Bool,
        requiresConfirmation: Bool,
        bytes: [UInt8]
    ) {
        self.normalizedText = normalizedText
        self.isMultiline = isMultiline
        self.requiresConfirmation = requiresConfirmation
        self.bytes = bytes
    }
}

package enum TerminalPastePolicy {
    private static let bracketedPasteStart = "\u{1B}[200~"
    private static let bracketedPasteEnd = "\u{1B}[201~"

    public static func prepare(
        _ text: String,
        bracketedPasteEnabled: Bool
    ) throws -> TerminalPastePayload {
        guard text.utf8.count <= TerminalConfiguration.pasteByteLimit else {
            throw TerminalPastePolicyError.payloadTooLarge(
                maximumBytes: TerminalConfiguration.pasteByteLimit
            )
        }
        guard !text.unicodeScalars.contains(where: {
            TerminalTextSecurityPolicy.isBidirectionalFormattingControl($0)
        }) else {
            throw TerminalPastePolicyError.containsBidirectionalFormattingControl
        }

        let normalizedText = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard normalizedText.utf8.count <= TerminalConfiguration.pasteByteLimit else {
            throw TerminalPastePolicyError.payloadTooLarge(
                maximumBytes: TerminalConfiguration.pasteByteLimit
            )
        }

        if bracketedPasteEnabled,
           normalizedText.contains(bracketedPasteStart)
            || normalizedText.contains(bracketedPasteEnd) {
            throw TerminalPastePolicyError.containsBracketedPasteTerminator
        }

        let isMultiline = normalizedText.contains("\n")
        let containsControlCharacter = normalizedText.unicodeScalars.contains { scalar in
            guard scalar.value != 0x09, scalar.value != 0x0A else { return false }
            return scalar.properties.generalCategory == .control
        }

        let framedText: String
        if normalizedText.isEmpty {
            framedText = ""
        } else if bracketedPasteEnabled {
            framedText = bracketedPasteStart + normalizedText + bracketedPasteEnd
        } else {
            framedText = normalizedText
        }

        let framedBytes = Array(framedText.utf8)
        guard framedBytes.count <= TerminalConfiguration.pasteByteLimit else {
            throw TerminalPastePolicyError.payloadTooLarge(
                maximumBytes: TerminalConfiguration.pasteByteLimit
            )
        }

        return TerminalPastePayload(
            normalizedText: normalizedText,
            isMultiline: isMultiline,
            requiresConfirmation: isMultiline || containsControlCharacter,
            bytes: framedBytes
        )
    }
}

package enum TerminalPastePolicyError: Error, Equatable, Sendable {
    case payloadTooLarge(maximumBytes: Int)
    case containsBracketedPasteTerminator
    case containsBidirectionalFormattingControl
}
