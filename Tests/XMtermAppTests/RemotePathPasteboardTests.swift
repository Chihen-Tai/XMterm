import AppKit
import Foundation
import Testing
import XMtermRemote
@testable import XMtermApp

@Suite("Remote path pasteboard")
@MainActor
struct RemotePathPasteboardTests {
    @Test("[FILE-COPY-001] exact path copy preserves spaces Unicode and leading hyphens", arguments: [
        "/team/design notes",
        "/研究/資料",
        "/team/-draft"
    ])
    func exactPathCopyPreservesText(_ value: String) throws {
        let path = try RemotePath(rawBytes: Array(value.utf8))

        #expect(RemotePathCopyText.text(for: .path, from: path) == value)
    }

    @Test("[FILE-COPY-001] name and parent copy are component aware")
    func nameAndParentAreComponentAware() throws {
        let path = try RemotePath(rawBytes: Array("/研究/design notes".utf8))

        #expect(RemotePathCopyText.text(for: .name, from: path) == "design notes")
        #expect(RemotePathCopyText.text(for: .parentDirectory, from: path) == "/研究")
    }

    @Test("[FILE-COPY-001] root has exact path and quoted forms but no name or parent")
    func rootAvailabilityIsMeaningful() {
        #expect(RemotePathCopyText.text(for: .path, from: .root) == "/")
        #expect(RemotePathCopyText.text(for: .shellQuotedPath, from: .root) == "'/'")
        #expect(RemotePathCopyText.text(for: .name, from: .root) == nil)
        #expect(RemotePathCopyText.text(for: .parentDirectory, from: .root) == nil)
    }

    @Test("[FILE-COPY-001] shell quoting uses the existing POSIX single quote encoding")
    func shellQuoteHandlesApostrophesAsPlainText() throws {
        let path = try RemotePath(rawBytes: Array("/team/O'Brien notes".utf8))

        let text = RemotePathCopyText.text(for: .shellQuotedPath, from: path)

        #expect(text == "'/team/O'\"'\"'Brien notes'")
        #expect(text == path.posixShellQuotedString)
        #expect(text?.contains("\n") == false)
        #expect(text?.contains("\r") == false)
    }

    @Test("[FILE-COPY-001] invalid UTF-8 disables every exact-text action")
    func invalidUTF8DisablesExactCopy() throws {
        let path = try RemotePath(rawBytes: [0x2F, 0x62, 0x61, 0x64, 0x80])

        for action in RemotePathCopyAction.allCases {
            #expect(RemotePathCopyText.text(for: action, from: path) == nil)
        }
    }

    @Test("[FILE-COPY-001] copy writes one exact string and appends no Return")
    func copyWritesOnlyExactText() throws {
        let writer = RecordingRemotePathPasteboardWriter()
        let pasteboard = RemotePathPasteboard(writer: writer)
        let path = try RemotePath(rawBytes: Array("/team/O'Brien notes".utf8))

        let didWrite = pasteboard.copy(.shellQuotedPath, from: path)

        #expect(didWrite)
        #expect(writer.writes == ["'/team/O'\"'\"'Brien notes'"])
        #expect(writer.writes.first?.contains("\n") == false)
        #expect(writer.writes.first?.contains("\r") == false)
    }

    @Test("[FILE-COPY-001] writer failure is returned without retrying or changing text")
    func writerFailureIsReturned() throws {
        let writer = RecordingRemotePathPasteboardWriter(result: false)
        let pasteboard = RemotePathPasteboard(writer: writer)
        let path = try RemotePath(rawBytes: Array("/-fixture".utf8))

        #expect(!pasteboard.copy(.path, from: path))
        #expect(writer.writes == ["/-fixture"])
    }

    @Test("[FILE-COPY-001] unavailable exact text never reaches the writer")
    func unavailableTextDoesNotWrite() throws {
        let writer = RecordingRemotePathPasteboardWriter()
        let pasteboard = RemotePathPasteboard(writer: writer)
        let path = try RemotePath(rawBytes: [0x2F, 0x80])

        #expect(!pasteboard.copy(.path, from: path))
        #expect(writer.writes.isEmpty)
    }

    @Test("[FILE-COPY-001] AppKit adapter replaces contents with one string item only")
    func appKitAdapterWritesOneStringItem() {
        let systemPasteboard = NSPasteboard(
            name: NSPasteboard.Name("XMterm.RemotePathPasteboardTests.\(UUID())")
        )
        let writer = AppKitRemotePathPasteboardWriter(pasteboard: systemPasteboard)

        #expect(writer.writeSinglePlainTextItem("/exact/path"))
        #expect(systemPasteboard.pasteboardItems?.count == 1)
        #expect(systemPasteboard.pasteboardItems?.first?.types == [.string])
        #expect(systemPasteboard.string(forType: .string) == "/exact/path")
    }
}

@MainActor
private final class RecordingRemotePathPasteboardWriter: RemotePathPasteboardWriting {
    private let result: Bool
    private(set) var writes: [String] = []

    init(result: Bool = true) {
        self.result = result
    }

    func writeSinglePlainTextItem(_ text: String) -> Bool {
        writes.append(text)
        return result
    }
}
