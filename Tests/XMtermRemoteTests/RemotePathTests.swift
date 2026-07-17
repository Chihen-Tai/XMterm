import Testing
@testable import XMtermRemote

@Suite("Raw remote paths")
struct RemotePathTests {
    @Test("[FILE-XFER-004] Root, parent, append, and repeated slashes stay component-aware")
    func rootParentAppendAndRepeatedSlashParsing() throws {
        let root = RemotePath.root
        #expect(root.components.isEmpty)
        #expect(root.rawBytes == [0x2F])
        #expect(root.parent == nil)
        #expect(root.losslessString == "/")

        let parsed = try RemotePath(rawBytes: Array("///alpha//beta///".utf8))
        #expect(parsed.rawBytes == Array("/alpha/beta".utf8))
        #expect(parsed.components.map(\.losslessString) == ["alpha", "beta"])
        #expect(parsed.parent?.losslessString == "/alpha")
        #expect(parsed.parent?.parent == root)
        #expect(try RemotePath(rawBytes: Array("////".utf8)) == root)

        let gamma = try RemotePathComponent(rawBytes: Array("gamma".utf8))
        let appended = try parsed.appending(gamma)
        #expect(appended.losslessString == "/alpha/beta/gamma")
        #expect(parsed.losslessString == "/alpha/beta")
    }

    @Test("[FILE-XFER-004] Components and parsed paths reject invalid remote input")
    func invalidComponentsAndPathsAreRejected() {
        #expect(throws: RemotePathValidationError.emptyComponent) {
            try RemotePathComponent(rawBytes: [])
        }
        #expect(throws: RemotePathValidationError.slashInComponent) {
            try RemotePathComponent(rawBytes: Array("a/b".utf8))
        }
        #expect(throws: RemotePathValidationError.nulByte) {
            try RemotePathComponent(rawBytes: [0x61, 0x00, 0x62])
        }
        #expect(throws: RemotePathValidationError.pathMustBeAbsolute) {
            try RemotePath(rawBytes: [])
        }
        #expect(throws: RemotePathValidationError.pathMustBeAbsolute) {
            try RemotePath(rawBytes: Array("relative/path".utf8))
        }
        #expect(throws: RemotePathValidationError.nulByte) {
            try RemotePath(rawBytes: [0x2F, 0x61, 0x00, 0x62])
        }
    }

    @Test("[FILE-CACHE-001, FILE-XFER-004] Component and absolute-path byte limits are exact")
    func componentAndPathLimitsAreExact() throws {
        let fullComponent = try RemotePathComponent(
            rawBytes: Array(repeating: 0x61, count: RemotePathComponent.maximumRawByteCount)
        )
        #expect(fullComponent.rawBytes.count == 4_096)
        #expect(
            throws: RemotePathValidationError.componentTooLong(
                maximum: 4_096,
                actual: 4_097
            )
        ) {
            try RemotePathComponent(rawBytes: Array(repeating: 0x61, count: 4_097))
        }

        let maximumComponents = Array(repeating: fullComponent, count: 7) + [
            try RemotePathComponent(rawBytes: Array(repeating: 0x62, count: 4_088))
        ]
        let maximumPath = try RemotePath(components: maximumComponents)
        #expect(maximumPath.rawBytes.count == RemotePath.maximumRawByteCount)
        #expect(maximumPath.rawBytes.count == 32_768)

        #expect(
            throws: RemotePathValidationError.pathTooLong(
                maximum: 32_768,
                actual: 32_769
            )
        ) {
            try RemotePath(rawBytes: [0x2F] + Array(repeating: 0x61, count: 32_768))
        }
    }

    @Test("[FILE-XFER-004] Legal names preserve exact bytes without Unicode normalization")
    func legalAsciiUnicodeAndSpecialNamesRoundTrip() throws {
        let names = [
            "plain.txt",
            "é",
            "e\u{301}",
            "研究資料",
            "rocket-🚀",
            "family-👨‍👩‍👧‍👦",
            "two words",
            "it's-here",
            "-leading-hyphen",
            ".dotfile"
        ]

        for name in names {
            let component = try RemotePathComponent(rawBytes: Array(name.utf8))
            #expect(component.rawBytes == Array(name.utf8))
            #expect(component.losslessString == name)
            #expect(component.escapedDisplayString == name)
        }

        let composed = try RemotePathComponent(rawBytes: Array("é".utf8))
        let decomposed = try RemotePathComponent(rawBytes: Array("e\u{301}".utf8))
        #expect(composed != decomposed)
        #expect(composed.rawBytes != decomposed.rawBytes)
    }

    @Test("[FILE-COPY-001, FILE-XFER-004] Invalid UTF-8 and controls display safely without changing identity")
    func invalidUTF8AndControlBytesUseEscapedDisplay() throws {
        let bytes = Array("line".utf8) + [0x0A, 0x1B, 0xFF, 0x5C] + Array("tail".utf8)
        let component = try RemotePathComponent(rawBytes: bytes)
        let path = try RemotePath(components: [component])

        #expect(component.rawBytes == bytes)
        #expect(component.losslessString == nil)
        #expect(component.escapedDisplayString == "line\\u{A}\\u{1B}\\xFF\\\\tail")
        #expect(path.escapedDisplayString == "/line\\u{A}\\u{1B}\\xFF\\\\tail")
        #expect(path.losslessString == nil)
        #expect(path.posixShellQuotedString == nil)
    }

    @Test("[FILE-COPY-001, FILE-XFER-004] Unicode bidi controls are escaped without changing bytes")
    func unsafeUnicodeFormattingControlsAreEscapedWithoutChangingIdentity() throws {
        let text = "report\u{202E}.txt\u{2066}visible\u{2069}"
        let rawBytes = Array(text.utf8)
        let component = try RemotePathComponent(rawBytes: rawBytes)
        let path = try RemotePath(components: [component])

        #expect(component.rawBytes == rawBytes)
        #expect(component.losslessString == text)
        #expect(
            component.escapedDisplayString
                == "report\\u{202E}.txt\\u{2066}visible\\u{2069}"
        )
        #expect(
            path.escapedDisplayString
                == "/report\\u{202E}.txt\\u{2066}visible\\u{2069}"
        )
    }

    @Test("[FILE-XFER-004] Equality and hashing use immutable raw-byte identity")
    func equalityHashingAndExposedCopiesPreserveIdentity() throws {
        let original = try RemotePath(rawBytes: Array("/研究/raw.bin".utf8))
        let rebuilt = try RemotePath(components: original.components)
        var exposedComponents = original.components
        var exposedBytes = exposedComponents[0].rawBytes

        exposedComponents.removeLast()
        exposedBytes[0] = 0x58

        #expect(original == rebuilt)
        #expect(Set([original, rebuilt]).count == 1)
        #expect(original.losslessString == "/研究/raw.bin")
        #expect(original.components.count == 2)
        #expect(original.components[0].losslessString == "研究")
    }

    @Test("[FILE-COPY-001] Breadcrumbs and POSIX quoting are derived from structured paths")
    func breadcrumbsAndShellQuotingAreSafe() throws {
        let path = try RemotePath(rawBytes: Array("/work/研究/it's here".utf8))

        #expect(
            path.breadcrumbPaths.compactMap(\.losslessString) == [
                "/",
                "/work",
                "/work/研究",
                "/work/研究/it's here"
            ]
        )
        #expect(path.posixShellQuotedString == "'/work/研究/it'\"'\"'s here'")
        #expect(RemotePath.root.posixShellQuotedString == "'/'")
    }

    @Test("[FILE-CACHE-001, FILE-XFER-004] Maximum-depth breadcrumbs share storage and stay linear")
    func maximumDepthBreadcrumbsShareStorageAndStayLinear() throws {
        let component = try RemotePathComponent(rawBytes: [0x61])
        let componentCount = RemotePath.maximumRawByteCount / 2
        let path = try RemotePath(
            components: Array(repeating: component, count: componentCount)
        )
        #expect(componentCount == 16_384)
        #expect(path.rawBytes.count == RemotePath.maximumRawByteCount)

        let clock = ContinuousClock()
        let startedAt = clock.now
        let breadcrumbs = path.breadcrumbPaths
        let elapsed = startedAt.duration(to: clock.now)

        #expect(breadcrumbs.count == 16_385)
        #expect(breadcrumbs.first == .root)
        #expect(breadcrumbs.last == path)
        #expect(breadcrumbs[8_192].components.count == 8_192)
        #expect(breadcrumbs[8_192].rawBytes.count == 16_384)
        #expect(elapsed < .milliseconds(250), "Breadcrumb construction took \(elapsed)")
    }
}
