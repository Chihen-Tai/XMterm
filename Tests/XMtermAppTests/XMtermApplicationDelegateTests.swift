import AppKit
import Testing
@testable import XMtermApp

@Suite("Application termination coordination", .serialized)
@MainActor
struct XMtermApplicationDelegateTests {
    @Test("Application shortcuts distinguish terminal close from window close")
    func applicationShortcutRoutingIsFocusIndependent() {
        #expect(
            ApplicationShortcutRouter.route(
                charactersIgnoringModifiers: "w",
                modifierFlags: [.command]
            ) == .closeTerminal
        )
        #expect(
            ApplicationShortcutRouter.route(
                charactersIgnoringModifiers: "W",
                modifierFlags: [.command, .shift]
            ) == .closeWindow
        )
        #expect(
            ApplicationShortcutRouter.route(
                charactersIgnoringModifiers: "w",
                modifierFlags: [.control]
            ) == nil
        )
        #expect(
            ApplicationShortcutRouter.route(
                charactersIgnoringModifiers: "w",
                modifierFlags: [.command, .option]
            ) == nil
        )
    }

    @Test("Menu normalization gives Command-W to Close Terminal")
    func closeTerminalOwnsCommandWInMenus() throws {
        let mainMenu = NSMenu(title: "Main")
        let fileMenu = NSMenu(title: "File")
        let terminalMenu = NSMenu(title: "Terminal")
        let fileRoot = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let terminalRoot = NSMenuItem(title: "Terminal", action: nil, keyEquivalent: "")
        let nativeClose = NSMenuItem(title: "Close", action: nil, keyEquivalent: "w")
        nativeClose.keyEquivalentModifierMask = [.command]
        let closeTerminal = NSMenuItem(title: "Close Terminal", action: nil, keyEquivalent: "")
        let closeWindow = NSMenuItem(title: "Close Window", action: nil, keyEquivalent: "w")
        closeWindow.keyEquivalentModifierMask = [.command, .shift]

        fileRoot.submenu = fileMenu
        terminalRoot.submenu = terminalMenu
        mainMenu.addItem(fileRoot)
        mainMenu.addItem(terminalRoot)
        fileMenu.addItem(nativeClose)
        terminalMenu.addItem(closeTerminal)
        terminalMenu.addItem(closeWindow)

        try ApplicationMenuShortcutNormalizer.normalize(mainMenu)

        #expect(nativeClose.keyEquivalent.isEmpty)
        #expect(closeTerminal.keyEquivalent == "w")
        #expect(closeTerminal.keyEquivalentModifierMask == [.command])
        #expect(closeWindow.keyEquivalent == "w")
        #expect(closeWindow.keyEquivalentModifierMask == [.command, .shift])
    }

    @Test("A synchronous zero-session decision replies only after terminateLater is returned")
    func synchronousTerminationDecisionIsDeferred() async {
        var replies: [Bool] = []
        let delegate = XMtermApplicationDelegate { _, shouldTerminate in
            replies.append(shouldTerminate)
        }
        delegate.onTerminationRequested = { completion in
            completion(true)
        }

        let result = delegate.applicationShouldTerminate(NSApplication.shared)

        #expect(result == .terminateLater)
        #expect(replies.isEmpty)
        await Task.yield()
        await Task.yield()
        #expect(replies == [true])
    }

    @Test("A second quit request cannot replace an outstanding AppKit reply")
    func duplicateTerminationRequestIsCancelled() async {
        var pendingReply: XMtermApplicationDelegate.TerminationReply?
        var replies: [Bool] = []
        let delegate = XMtermApplicationDelegate { _, shouldTerminate in
            replies.append(shouldTerminate)
        }
        delegate.onTerminationRequested = { completion in
            pendingReply = completion
        }

        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        pendingReply?(false)
        await Task.yield()
        await Task.yield()
        #expect(replies == [false])
    }
}
