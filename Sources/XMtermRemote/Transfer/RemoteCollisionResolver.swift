import Foundation

public enum RemoteCollisionResolver {
    public static let maximumCandidateCount = 10_000

    public static func keepBothComponent(
        original: RemotePathComponent,
        isAvailable: (RemotePathComponent) -> Bool
    ) throws -> RemotePathComponent {
        for ordinal in 1...maximumCandidateCount {
            let suffix = ordinal == 1 ? " copy" : " copy \(ordinal)"
            let rawCandidate = candidateBytes(original: original, suffix: suffix)
            guard rawCandidate.count <= RemotePathComponent.maximumRawByteCount else {
                throw RemoteFileError(category: .limitExceeded)
            }
            let candidate: RemotePathComponent
            do {
                candidate = try RemotePathComponent(rawBytes: rawCandidate)
            } catch {
                throw RemoteFileError(category: .invalidOperation)
            }
            if isAvailable(candidate) {
                return candidate
            }
        }
        throw RemoteFileError(category: .limitExceeded)
    }

    private static func candidateBytes(
        original: RemotePathComponent,
        suffix: String
    ) -> [UInt8] {
        guard let name = original.losslessString,
              let extensionStart = losslessExtensionStart(in: name) else {
            return original.rawBytes + Array(suffix.utf8)
        }
        return Array(name[..<extensionStart].utf8)
            + Array(suffix.utf8)
            + Array(name[extensionStart...].utf8)
    }

    private static func losslessExtensionStart(in name: String) -> String.Index? {
        guard let dot = name.lastIndex(of: "."),
              dot != name.startIndex,
              name.index(after: dot) != name.endIndex else {
            return nil
        }
        return dot
    }
}
