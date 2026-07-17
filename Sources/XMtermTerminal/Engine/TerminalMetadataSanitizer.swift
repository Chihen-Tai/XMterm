import Foundation
import XMtermCore

/// Sanitizes untrusted metadata emitted by a terminal process before it reaches UI state.
package enum TerminalMetadataSanitizer {
    package static let maximumTitleLength = TerminalTitlePolicy.maximumCharacterCount
    package static let maximumCurrentDirectoryLength = 4_096

    package static func title(_ rawTitle: String) -> String? {
        TerminalTitlePolicy.sanitize(rawTitle)
    }

    package static func currentDirectory(_ rawDirectory: String?) -> String? {
        guard let rawDirectory else { return nil }

        let scalars = rawDirectory.unicodeScalars
            .prefix(maximumCurrentDirectoryLength)
            .filter {
                !CharacterSet.controlCharacters.contains($0)
                    && !TerminalTextSecurityPolicy.isBidirectionalFormattingControl($0)
            }
        let result = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }
}
