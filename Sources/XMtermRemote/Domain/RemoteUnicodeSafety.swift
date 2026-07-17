enum RemoteUnicodeSafety {
    static func escaped(
        _ scalars: [Unicode.Scalar],
        maximumByteCount: Int? = nil
    ) -> String {
        var result = ""
        var byteCount = 0

        for index in scalars.indices {
            let rendered = renderedScalar(at: index, in: scalars)
            let renderedByteCount = rendered.utf8.count
            if let maximumByteCount,
               byteCount + renderedByteCount > maximumByteCount {
                break
            }
            result += rendered
            byteCount += renderedByteCount
        }
        return result
    }

    private static func renderedScalar(
        at index: Int,
        in scalars: [Unicode.Scalar]
    ) -> String {
        let scalar = scalars[index]
        if scalar.value == 0x5C { return "\\\\" }
        if scalar.value == 0x200D, isEmojiJoiner(at: index, in: scalars) {
            return String(scalar)
        }

        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator:
            return unicodeEscape(scalar)
        default:
            return String(scalar)
        }
    }

    private static func isEmojiJoiner(
        at index: Int,
        in scalars: [Unicode.Scalar]
    ) -> Bool {
        guard let previous = neighboringScalar(before: index, in: scalars),
              let next = neighboringScalar(after: index, in: scalars) else {
            return false
        }
        return isEmojiNeighbor(previous) && isEmojiNeighbor(next)
    }

    private static func neighboringScalar(
        before index: Int,
        in scalars: [Unicode.Scalar]
    ) -> Unicode.Scalar? {
        var candidate = index
        while candidate > scalars.startIndex {
            candidate -= 1
            let scalar = scalars[candidate]
            if !scalar.properties.isVariationSelector { return scalar }
        }
        return nil
    }

    private static func neighboringScalar(
        after index: Int,
        in scalars: [Unicode.Scalar]
    ) -> Unicode.Scalar? {
        var candidate = index + 1
        while candidate < scalars.endIndex {
            let scalar = scalars[candidate]
            if !scalar.properties.isVariationSelector { return scalar }
            candidate += 1
        }
        return nil
    }

    private static func isEmojiNeighbor(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value > 0x7F && scalar.properties.isEmoji
    }

    private static func unicodeEscape(_ scalar: Unicode.Scalar) -> String {
        "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
    }
}
