import AppKit
import Foundation
@preconcurrency import SwiftTerm
import XMtermCore

private struct SendableNSEvent: @unchecked Sendable {
    let value: NSEvent
}

private final class TerminalViewResources {
    var resizeWorkItem: DispatchWorkItem?
    var localEventMonitor: Any?

    deinit {
        resizeWorkItem?.cancel()
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
        }
    }
}

package enum TerminalPasteRejection: Error, Equatable, Sendable {
    case pasteboardDoesNotContainText
    case clipboardWriteFailed
    case confirmationUnavailable
    case policy(TerminalPastePolicyError)
    case unexpectedPolicyFailure

    package var userFacingMessage: String {
        switch self {
        case .pasteboardDoesNotContainText:
            "The clipboard does not contain text that XMterm can paste."
        case .clipboardWriteFailed:
            "XMterm could not copy the selected terminal text to the clipboard."
        case .confirmationUnavailable:
            "XMterm could not confirm this potentially unsafe paste."
        case let .policy(.payloadTooLarge(maximumBytes)):
            "The clipboard text is larger than XMterm's \(maximumBytes)-byte paste limit."
        case .policy(.containsBracketedPasteTerminator):
            "The clipboard text contains terminal paste control markers and was not pasted."
        case .policy(.containsBidirectionalFormattingControl):
            "The clipboard text contains hidden bidirectional formatting controls and was not pasted."
        case .unexpectedPolicyFailure:
            "XMterm could not safely prepare the clipboard text for pasting."
        }
    }
}

/// AppKit adapter around one SwiftTerm terminal engine instance.
///
/// A terminal session owns and retains this view for its entire lifetime. The view never owns a
/// PTY descriptor or child process; all process I/O crosses the synchronous callbacks below.
@MainActor
package final class XMtermTerminalView: TerminalView {
    package typealias PasteConfirmationHandler = (
        _ payload: TerminalPastePayload,
        _ completion: @escaping @MainActor (Bool) -> Void
    ) -> Void

    package var onBytesToPTY: (([UInt8]) -> Void)?
    package var onGridSizeChanged: ((TerminalGridSize) -> Void)?
    package var onTitleChanged: ((String) -> Void)?
    package var onCurrentDirectoryChanged: ((String?) -> Void)?
    package var onScrollPositionChanged: ((Double) -> Void)?
    package var onVisibleRangeChanged: (() -> Void)?
    package var onLocalAction: ((TerminalLocalAction) -> Void)?
    package var onPasteConfirmationRequested: PasteConfirmationHandler?
    package var onPasteRejected: ((TerminalPasteRejection) -> Void)?
    package var onOSC52Denied: (() -> Void)?

    /// The owning session disables this when its child is no longer running.
    package var acceptsInput = true

    private var resizeState = TerminalResizeCoalescingState()
    private var outputSecurityFilter = TerminalOutputSecurityFilter()
    private let delegateBridge = XMtermTerminalViewDelegateBridge()
    private let resources = TerminalViewResources()

    package override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureEngine()
    }

    package required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureEngine()
    }

    package override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateLocalEventMonitor()
    }

    package func focus() {
        window?.makeFirstResponder(self)
    }

    package func jumpToLatestOutput() {
        scroll(toPosition: 1)
        onScrollPositionChanged?(scrollPosition)
    }

    /// SwiftTerm reports position zero both for the top of history and for a buffer that has no
    /// scrollback yet. `canScroll` disambiguates those states so the first shell prompt is not
    /// incorrectly presented as unseen output.
    package var isViewingScrollback: Bool {
        canScroll && scrollPosition < 0.999
    }

    package func clearSelection() {
        selectNone()
    }

    /// Feeds bytes received from a PTY through XMterm's restricted output-protocol boundary.
    package func receivePTYOutput(_ bytes: [UInt8]) {
        let safeBytes = outputSecurityFilter.process(bytes)
        guard !safeBytes.isEmpty else { return }
        feed(byteArray: safeBytes[...])
    }

    package func showFindBar() {
        let item = NSMenuItem()
        item.tag = Int(NSTextFinder.Action.showFindInterface.rawValue)
        performTextFinderAction(item)
    }

    package func paste(text: String) {
        guard acceptsInput else { return }

        let payload: TerminalPastePayload
        do {
            payload = try TerminalPastePolicy.prepare(
                text,
                bracketedPasteEnabled: getTerminal().bracketedPasteMode
            )
        } catch let error as TerminalPastePolicyError {
            onPasteRejected?(.policy(error))
            return
        } catch {
            onPasteRejected?(.unexpectedPolicyFailure)
            return
        }

        guard !payload.bytes.isEmpty else { return }
        guard payload.requiresConfirmation else {
            send(payload.bytes)
            return
        }
        guard let onPasteConfirmationRequested else {
            onPasteRejected?(.confirmationUnavailable)
            return
        }

        var confirmationResolved = false
        onPasteConfirmationRequested(payload) { [weak self] approved in
            guard !confirmationResolved else { return }
            confirmationResolved = true
            guard approved, let self, self.acceptsInput else { return }
            self.send(payload.bytes)
        }
    }

    @objc
    package override func paste(_ sender: Any) {
        guard let text = NSPasteboard.general.string(forType: .string) else {
            onPasteRejected?(.pasteboardDoesNotContainText)
            return
        }
        paste(text: text)
    }

    @objc
    package override func copy(_ sender: Any) {
        guard let selection = getSelection(), !selection.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(selection, forType: .string) else {
            onPasteRejected?(.clipboardWriteFailed)
            return
        }
    }

    package override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu(title: "Terminal")
        menu.autoenablesItems = false
        menu.addItem(
            menuItem(
                title: "Copy",
                action: #selector(copy(_:)),
                key: "c",
                isEnabled: getSelection()?.isEmpty == false
            )
        )
        menu.addItem(
            menuItem(
                title: "Paste",
                action: #selector(paste(_:)),
                key: "v",
                isEnabled: acceptsInput && NSPasteboard.general.string(forType: .string) != nil
            )
        )
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "Select All", action: #selector(selectAll(_:)), key: "a"))
        menu.addItem(
            menuItem(
                title: "Clear Selection",
                action: #selector(clearSelectionAction(_:)),
                isEnabled: selectionActive
            )
        )
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "Find…", action: #selector(showFindAction(_:)), key: "f"))
        menu.addItem(menuItem(title: "Jump to Latest Output", action: #selector(jumpToLatestAction(_:))))
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "Close Terminal", action: #selector(closeTerminalAction(_:)), key: "w"))
        return menu
    }

    package override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }

        switch inputRoute(for: event) {
        case .local(.unhandledCommand):
            return super.performKeyEquivalent(with: event)
        case let .local(action):
            performLocalAction(action)
            return true
        case .engine, .ptyBytes(_):
            return super.performKeyEquivalent(with: event)
        }
    }

    package override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        beginMouseEvent(event)
        defer { finishMouseEvent() }
        super.mouseDown(with: event)
    }

    package override func mouseUp(with event: NSEvent) {
        beginMouseEvent(event)
        defer { finishMouseEvent() }
        super.mouseUp(with: event)
    }

    package override func mouseDragged(with event: NSEvent) {
        beginMouseEvent(event)
        defer { finishMouseEvent() }
        super.mouseDragged(with: event)
    }

    func receiveGridSize(columns: Int, rows: Int) {
        guard columns > 0, rows > 0 else { return }
        enqueueResize(
            TerminalGridSize(
                columns: UInt16(clamping: columns),
                rows: UInt16(clamping: rows)
            )
        )
    }

    func receiveTitle(_ title: String) {
        guard let title = TerminalMetadataSanitizer.title(title) else { return }
        onTitleChanged?(title)
    }

    func receiveCurrentDirectory(_ directory: String?) {
        onCurrentDirectoryChanged?(TerminalMetadataSanitizer.currentDirectory(directory))
    }

    func receiveBytes(_ data: [UInt8]) {
        guard acceptsInput else { return }
        onBytesToPTY?(data)
    }

    func receiveScrollPosition(_ position: Double) {
        onScrollPositionChanged?(min(max(position, 0), 1))
    }

    func receiveVisibleRangeChange() {
        onVisibleRangeChanged?()
    }

    func receiveOSC52Denial() {
        onOSC52Denied?()
    }

    private func configureEngine() {
        delegateBridge.owner = self
        terminalDelegate = delegateBridge
        backspaceSendsControlH = false
        optionAsMetaKey = true
        allowMouseReporting = false
        linkReporting = .none
        notifyUpdateChanges = true

        let terminal = getTerminal()
        terminal.silentLog = true
        terminal.options.termName = TerminalConfiguration.termName
        terminal.options.enableSixelReported = false
        terminal.options.kittyImageCacheLimitBytes = TerminalConfiguration.kittyImageCacheLimitBytes
        changeScrollback(TerminalConfiguration.scrollbackLimit)
        terminal.registerOscHandler(code: 52) { [weak delegateBridge] _ in
            delegateBridge?.denyOSC52()
        }
    }

    private func updateLocalEventMonitor() {
        if let localEventMonitor = resources.localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            resources.localEventMonitor = nil
        }
        guard window != nil else { return }

        resources.localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .scrollWheel]
        ) { [weak self] event in
            guard Thread.isMainThread else { return event }
            let eventBox = SendableNSEvent(value: event)
            let consumed = MainActor.assumeIsolated {
                self?.consumeMonitoredEvent(eventBox.value) ?? false
            }
            return consumed ? nil : event
        }
    }

    private func consumeMonitoredEvent(_ event: NSEvent) -> Bool {
        guard let window, event.window === window else { return false }

        switch event.type {
        case .keyDown:
            guard window.firstResponder === self else { return false }
            switch inputRoute(for: event) {
            case let .ptyBytes(bytes):
                if acceptsInput { send(bytes) }
                return true
            case .local(.unhandledCommand):
                return false
            case let .local(action):
                performLocalAction(action)
                return true
            case .engine:
                return prepareForEngineInput(event)
            }
        case .scrollWheel:
            let localPoint = convert(event.locationInWindow, from: nil)
            guard bounds.contains(localPoint) else { return false }
            allowMouseReporting = acceptsInput
                && getTerminal().mouseMode != .off
                && !event.modifierFlags.contains(.option)
            DispatchQueue.main.async { [weak self] in
                self?.allowMouseReporting = false
            }
            return false
        default:
            return false
        }
    }

    private func enqueueResize(_ size: TerminalGridSize) {
        resizeState = resizeState.receiving(size)
        guard resources.resizeWorkItem == nil else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let firing = self.resizeState.firing()
            self.resizeState = firing.state
            self.resources.resizeWorkItem = nil
            if let emittedSize = firing.emittedSize {
                self.onGridSizeChanged?(emittedSize)
            }
        }
        resources.resizeWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + TerminalConfiguration.resizeCoalescingInterval,
            execute: workItem
        )
    }

    private func menuItem(
        title: String,
        action: Selector,
        key: String = "",
        isEnabled: Bool = true
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.isEnabled = isEnabled
        return item
    }

    @objc
    private func clearSelectionAction(_ sender: Any?) {
        clearSelection()
    }

    @objc
    private func showFindAction(_ sender: Any?) {
        showFindBar()
    }

    @objc
    private func jumpToLatestAction(_ sender: Any?) {
        jumpToLatestOutput()
    }

    @objc
    private func closeTerminalAction(_ sender: Any?) {
        onLocalAction?(.closeTab)
    }
}
