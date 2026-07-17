import AppKit
import XMtermRemote

enum RemotePathCopyAction: CaseIterable, Equatable, Hashable, Sendable {
    case path
    case name
    case parentDirectory
    case shellQuotedPath
}

enum RemotePathCopyText {
    static func text(
        for action: RemotePathCopyAction,
        from path: RemotePath
    ) -> String? {
        guard path.losslessString != nil else { return nil }

        return switch action {
        case .path:
            path.losslessString
        case .name:
            path.components.last?.losslessString
        case .parentDirectory:
            path.parent?.losslessString
        case .shellQuotedPath:
            path.posixShellQuotedString
        }
    }
}

@MainActor
protocol RemotePathPasteboardWriting: AnyObject {
    func writeSinglePlainTextItem(_ text: String) -> Bool
}

@MainActor
struct RemotePathPasteboard {
    private let writer: any RemotePathPasteboardWriting

    init(writer: any RemotePathPasteboardWriting) {
        self.writer = writer
    }

    @discardableResult
    func copy(_ action: RemotePathCopyAction, from path: RemotePath) -> Bool {
        guard let text = RemotePathCopyText.text(for: action, from: path) else {
            return false
        }
        return writer.writeSinglePlainTextItem(text)
    }
}

@MainActor
final class AppKitRemotePathPasteboardWriter: RemotePathPasteboardWriting {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    func writeSinglePlainTextItem(_ text: String) -> Bool {
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string) else { return false }

        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }
}
