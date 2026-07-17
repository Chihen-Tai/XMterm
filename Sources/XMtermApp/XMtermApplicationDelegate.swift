import AppKit

private struct SendableApplicationEvent: @unchecked Sendable {
    let value: NSEvent
}

@MainActor
final class XMtermApplicationDelegate: NSObject, NSApplicationDelegate {
    typealias TerminationReply = @MainActor (Bool) -> Void
    typealias TerminationRequest = @MainActor (@escaping TerminationReply) -> Void
    typealias ReplyHandler = @MainActor (NSApplication, Bool) -> Void

    var onTerminationRequested: TerminationRequest?
    var onCloseTerminalRequested: (@MainActor () -> Void)?
    var onCloseWindowRequested: (@MainActor () -> Void)?
    private var isAwaitingTerminationReply = false
    private var shortcutMonitor: Any?
    private let replyHandler: ReplyHandler

    override init() {
        replyHandler = { application, shouldTerminate in
            application.reply(toApplicationShouldTerminate: shouldTerminate)
        }
        super.init()
    }

    init(replyHandler: @escaping ReplyHandler) {
        self.replyHandler = replyHandler
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installShortcutMonitorIfNeeded()
        normalizeMainMenuIfAvailable()
        Task { @MainActor [weak self] in
            self?.normalizeMainMenuIfAvailable()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        normalizeMainMenuIfAvailable()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let shortcutMonitor {
            NSEvent.removeMonitor(shortcutMonitor)
            self.shortcutMonitor = nil
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isAwaitingTerminationReply else { return .terminateCancel }
        guard let onTerminationRequested else { return .terminateNow }

        isAwaitingTerminationReply = true
        onTerminationRequested { [weak self, weak sender] shouldTerminate in
            Task { @MainActor [weak self, weak sender] in
                // AppKit must observe `.terminateLater` before receiving the reply. This also
                // covers the zero-session path, where the workspace decides synchronously. A
                // new main-actor task cannot run until this delegate method returns.
                guard let self else { return }
                self.isAwaitingTerminationReply = false
                if let sender {
                    self.replyHandler(sender, shouldTerminate)
                }
            }
        }
        return .terminateLater
    }

    private func installShortcutMonitorIfNeeded() {
        guard shortcutMonitor == nil else { return }
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard Thread.isMainThread else { return event }
            let eventBox = SendableApplicationEvent(value: event)
            let consumed = MainActor.assumeIsolated {
                self?.consumeApplicationShortcut(eventBox.value) ?? false
            }
            return consumed ? nil : event
        }
    }

    private func consumeApplicationShortcut(_ event: NSEvent) -> Bool {
        guard let action = ApplicationShortcutRouter.route(
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifierFlags: event.modifierFlags
        ) else {
            return false
        }

        switch action {
        case .closeTerminal:
            guard let onCloseTerminalRequested else { return false }
            onCloseTerminalRequested()
        case .closeWindow:
            guard let onCloseWindowRequested else { return false }
            onCloseWindowRequested()
        }
        return true
    }

    private func normalizeMainMenuIfAvailable() {
        guard let mainMenu = NSApplication.shared.mainMenu else { return }
        try? ApplicationMenuShortcutNormalizer.normalize(mainMenu)
    }
}
