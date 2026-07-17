import AppKit
import Testing
import XMtermCore
@testable import XMtermTerminal

@Suite("SwiftTerm adapter", .serialized)
struct SwiftTermAdapterTests {
    @Test("[TERM-RENDER-001] engine uses bounded native configuration")
    @MainActor
    func engineUsesBoundedNativeConfiguration() {
        let view = XMtermTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let options = view.getTerminal().options

        #expect(options.termName == TerminalConfiguration.termName)
        #expect(options.scrollback == TerminalConfiguration.scrollbackLimit)
        #expect(!options.enableSixelReported)
        #expect(options.kittyImageCacheLimitBytes == TerminalConfiguration.kittyImageCacheLimitBytes)
        #expect(view.getTerminal().silentLog, "SwiftTerm's configurable diagnostics must be disabled")
        #expect(!view.backspaceSendsControlH, "Backspace must send DEL (0x7f)")
        #expect(view.optionAsMetaKey, "Option must use Escape-prefix Meta behavior")
        #expect(!view.allowMouseReporting, "Selection must remain local between mouse events")
        #expect(!view.isUsingMetalRenderer, "Phase 1 deliberately uses CoreGraphics")

        switch view.linkReporting {
        case .none:
            break
        case .explicit, .implicit:
            Issue.record("Terminal links must not be activated in Phase 1")
        }
    }

    @Test("Hostile output protocols are filtered before SwiftTerm dispatch")
    @MainActor
    func hostileOutputProtocolsDoNotReachSwiftTerm() {
        let view = XMtermTerminalView(frame: .zero)
        var responses: [[UInt8]] = []
        view.onBytesToPTY = { responses.append($0) }

        let hostileSequences = [
            "\u{1B}]1337;File=name=dGVzdA==:cGF5bG9hZA==\u{7}",
            "\u{1B}]52;c;WE10ZXJtIHNlY3JldA==\u{7}",
            "\u{1B}_Gf=100,t=t;L3RtcC94bXRlcm0tdGVzdA==\u{1B}\\",
            "\u{1B}Pq!999999999~\u{1B}\\"
        ]
        view.receivePTYOutput(Array(("safe" + hostileSequences.joined() + "text").utf8))

        #expect(
            view.getTerminal().getLine(row: 0)?.translateToString(trimRight: true) == "safetext"
        )
        #expect(responses.isEmpty)
    }

    @Test("[TERM-SCROLL-001] an empty buffer is following output, not reading history")
    @MainActor
    func emptyBufferDoesNotReportVisibleScrollback() {
        let view = XMtermTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))

        #expect(!view.canScroll)
        #expect(!view.isViewingScrollback)
    }

    @Test("[TERM-SEL-004] copied soft wraps omit artificial newlines and padding")
    @MainActor
    func copiedSoftWrapsPreserveLogicalLine() {
        let view = XMtermTerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 240))
        let logicalLine = String(repeating: "X", count: 160)
        view.feed(byteArray: Array((logicalLine + "\r\nHARD_BREAK").utf8)[...])

        view.selectAll(nil)

        #expect(view.getSelection() == logicalLine + "\nHARD_BREAK")
    }

    @Test("[TERM-SEC-001] OSC 52 is denied before clipboard decoding")
    @MainActor
    func osc52IsDeniedByRegisteredHandler() {
        let view = XMtermTerminalView(frame: .zero)
        var denialCount = 0
        view.onOSC52Denied = {
            denialCount += 1
        }

        let encodedClipboardWrite = "\u{1B}]52;c;WE10ZXJtIHNlY3JldA==\u{7}"
        view.feed(byteArray: Array(encodedClipboardWrite.utf8)[...])

        #expect(denialCount == 1)
    }

    @Test("Terminal metadata is sanitized and bounded")
    func titleSanitizationRemovesControlsCollapsesWhitespaceAndBoundsLength() {
        let unsafe = "\u{1B}[31m  Local\u{0000}\nShell  " + String(repeating: "x", count: 300)
        let sanitized = TerminalMetadataSanitizer.title(unsafe)

        #expect(sanitized != nil)
        #expect(sanitized?.hasPrefix("[31m Local Shell ") == true)
        #expect(sanitized?.count == TerminalMetadataSanitizer.maximumTitleLength)
        #expect(
            sanitized?.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) == false
        )
    }

    @Test("Blank titles and unsafe current-directory controls are not forwarded")
    func blankTitleAndUnsafeCurrentDirectoryAreNotForwarded() {
        #expect(TerminalMetadataSanitizer.title("\u{0000}\n\t") == nil)
        #expect(
            TerminalMetadataSanitizer.currentDirectory("file:///Users/example\u{202E}\u{0000}\n")
                == "file:///Users/example"
        )
    }

    @Test("[TERM-KEY-001] delegate forwards byte chunks synchronously and in order")
    @MainActor
    func delegateForwardsByteChunksSynchronouslyAndInOrder() {
        let view = XMtermTerminalView(frame: .zero)
        var chunks: [[UInt8]] = []
        view.onBytesToPTY = { chunks.append($0) }

        view.send([0x03, 0x16])
        view.send([0x17, 0x06])

        #expect(chunks == [[0x03, 0x16], [0x17, 0x06]])
    }

    @Test("[TERM-CLIP-002] confirmed bracketed multiline paste is emitted exactly once")
    @MainActor
    func confirmedBracketedMultilinePasteIsEmittedExactlyOnce() {
        let view = XMtermTerminalView(frame: .zero)
        var chunks: [[UInt8]] = []
        view.onBytesToPTY = { chunks.append($0) }
        view.onPasteConfirmationRequested = { payload, completion in
            #expect(payload.requiresConfirmation)
            completion(true)
            completion(true)
        }
        view.feed(byteArray: Array("\u{1B}[?2004h".utf8)[...])

        view.paste(text: "first\nsecond")

        #expect(chunks == [Array("\u{1B}[200~first\nsecond\u{1B}[201~".utf8)])
    }

    @Test("[TERM-SEC-001] unsafe bidirectional paste is rejected with a typed policy error")
    @MainActor
    func unsafeBidirectionalPasteIsRejected() {
        let view = XMtermTerminalView(frame: .zero)
        var rejection: TerminalPasteRejection?
        var output: [[UInt8]] = []
        view.onPasteRejected = { rejection = $0 }
        view.onBytesToPTY = { output.append($0) }

        view.paste(text: "safe\u{202E}hidden")

        #expect(rejection == .policy(.containsBidirectionalFormattingControl))
        #expect(output.isEmpty)
    }

    @Test("[TERM-KEY-001] Command-T is consumed locally and never sent as terminal bytes")
    @MainActor
    func commandTStaysLocal() throws {
        let view = XMtermTerminalView(frame: .zero)
        var actions: [TerminalLocalAction] = []
        var output: [[UInt8]] = []
        view.onLocalAction = { actions.append($0) }
        view.onBytesToPTY = { output.append($0) }
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: .command,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "t",
                charactersIgnoringModifiers: "t",
                isARepeat: false,
                keyCode: 17
            )
        )

        #expect(view.performKeyEquivalent(with: event))
        #expect(actions == [.newTab])
        #expect(output.isEmpty)
    }

    @Test("[APP-003, TERM-SEL-002] clicking the terminal restores keyboard focus")
    @MainActor
    func mouseDownMakesTerminalFirstResponder() throws {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: window.contentView?.bounds ?? .zero)
        let terminal = XMtermTerminalView(frame: container.bounds)
        let otherResponder = NSTextField(frame: CGRect(x: 0, y: 0, width: 100, height: 24))
        container.addSubview(terminal)
        container.addSubview(otherResponder)
        window.contentView = container
        #expect(window.makeFirstResponder(otherResponder))

        let event = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: CGPoint(x: 20, y: 20),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            )
        )
        terminal.mouseDown(with: event)

        #expect(window.firstResponder === terminal)
    }

    @Test("[TERM-STATE-001, TERM-SEL-002] exited terminals keep mouse selection local")
    @MainActor
    func exitedTerminalBypassesStaleMouseReportingMode() throws {
        let view = XMtermTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        view.receivePTYOutput(Array("\u{1B}[?1000hfinal scrollback".utf8))
        #expect(view.getTerminal().mouseMode != .off)
        view.acceptsInput = false
        let event = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: CGPoint(x: 20, y: 20),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            )
        )

        view.beginMouseEvent(event)

        #expect(!view.allowMouseReporting)
        view.finishMouseEvent()
    }

    @Test("[TERM-SEL-002] physical Escape visibly clears selection before engine input")
    @MainActor
    func escapeClearsSelectionBeforeEngineInput() throws {
        let view = XMtermTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        view.feed(byteArray: Array("selected text\r\n".utf8)[...])
        view.selectAll(nil)
        #expect(view.selectionActive)

        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "\u{1B}",
                charactersIgnoringModifiers: "\u{1B}",
                isARepeat: false,
                keyCode: 53
            )
        )

        #expect(!view.prepareForEngineInput(event))
        #expect(!view.selectionActive)
    }

    @Test("[TAB-003] representable retains supplied view identity")
    @MainActor
    func representableRetainsSuppliedViewIdentity() {
        let view = XMtermTerminalView(frame: .zero)
        let representable = RetainedTerminalView(terminalView: view)

        #expect(representable.representedViewForTesting === view)
    }
}
