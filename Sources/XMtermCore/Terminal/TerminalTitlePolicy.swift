import Foundation

/// Sanitizes untrusted terminal metadata before it becomes visible tab state.
package enum TerminalTitlePolicy {
    package static let maximumCharacterCount = 160
    private static let maximumInputScalarCount = 4_096

    package static func sanitize(_ rawTitle: String) -> String? {
        var resultScalars: [UnicodeScalar] = []
        resultScalars.reserveCapacity(min(rawTitle.unicodeScalars.count, maximumInputScalarCount))
        var pendingSpace = false

        for scalar in rawTitle.unicodeScalars.prefix(maximumInputScalarCount) {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                pendingSpace = !resultScalars.isEmpty
                continue
            }
            guard scalar.properties.generalCategory != .control,
                  !TerminalTextSecurityPolicy.isBidirectionalFormattingControl(scalar) else {
                continue
            }

            if pendingSpace {
                resultScalars.append(" ")
                pendingSpace = false
            }
            resultScalars.append(scalar)
        }

        let cleaned = String(String.UnicodeScalarView(resultScalars))
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(maximumCharacterCount))
    }
}

package enum TerminalTextSecurityPolicy {
    package static func isBidirectionalFormattingControl(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x061C, 0x200E...0x200F, 0x202A...0x202E, 0x2066...0x2069:
            true
        default:
            false
        }
    }
}
