import Foundation
import Testing
@testable import XMtermCore

@Suite("Terminal configuration")
struct TerminalConfigurationTests {
    @Test("[TERM-SCROLL-001, TERM-SEC-001] Phase 1 values are explicit and bounded")
    func configurationUsesExplicitBoundedPhaseOneValues() {
        #expect(TerminalConfiguration.scrollbackLimit == 10_000)
        #expect(TerminalConfiguration.scrollbackLimit > 0)
        #expect(TerminalConfiguration.scrollbackLimit <= 100_000)
        #expect(TerminalConfiguration.kittyImageCacheLimitBytes == 0)
        #expect(TerminalConfiguration.resizeCoalescingInterval == 0.04)
        #expect(TerminalConfiguration.resizeCoalescingInterval > 0)
        #expect(TerminalConfiguration.termName == "xterm-256color")
        #expect(TerminalConfiguration.pasteByteLimit == 1_048_576)
    }
}

@Suite("Terminal exit status")
struct TerminalExitStatusTests {
    @Test("[TERM-STATE-001] Darwin wait status decodes exits and signals")
    func decodesNormalNonzeroAndSignalWaitStatuses() throws {
        #expect(try TerminalExitStatus(decodingDarwinWaitStatus: 0) == .exited(code: 0))
        #expect(try TerminalExitStatus(decodingDarwinWaitStatus: 7 << 8) == .exited(code: 7))
        #expect(try TerminalExitStatus(decodingDarwinWaitStatus: 15) == .signaled(signal: 15))
    }

    @Test("[TERM-STATE-001] Exit summaries are concise and user-facing")
    func exitSummariesAreConciseAndUserFacing() {
        #expect(TerminalExitStatus.exited(code: 0).summary == "Exited normally")
        #expect(TerminalExitStatus.exited(code: 7).summary == "Exited with status 7")
        #expect(TerminalExitStatus.signaled(signal: 15).summary == "Terminated by signal 15")
    }

    @Test("[TERM-STATE-001] Stopped and continued wait statuses are not terminal exits")
    func stoppedAndContinuedWaitStatusesAreNotTerminalExits() {
        do {
            _ = try TerminalExitStatus(decodingDarwinWaitStatus: (17 << 8) | 0x7F)
            Issue.record("Expected stopped wait status to be rejected")
        } catch {
            #expect(error as? TerminalWaitStatusDecodingError == .processStopped(signal: 17))
        }

        do {
            _ = try TerminalExitStatus(decodingDarwinWaitStatus: (0x13 << 8) | 0x7F)
            Issue.record("Expected continued wait status to be rejected")
        } catch {
            #expect(error as? TerminalWaitStatusDecodingError == .processContinued)
        }
    }
}

@Suite("Terminal lifecycle")
struct TerminalLifecycleTests {
    @Test("[TERM-PROC-001, TERM-STATE-001] Launch, close, and exit transition deterministically")
    func launchSuccessCloseAndTerminalExitTransitions() throws {
        let running = try TerminalLifecycle.starting.transitioned(by: .launchSucceeded)
        #expect(running == .running)

        let closing = try running.transitioned(by: .closeRequested)
        #expect(closing == .closing)
        #expect(
            try closing.transitioned(by: .processExited(.exited(code: 0)))
                == .exited(.exited(code: 0))
        )
    }

    @Test("[TERM-STATE-001] Normal, nonzero, and signal exits remain typed")
    func normalNonzeroAndSignalExitsRemainTyped() throws {
        for status in [
            TerminalExitStatus.exited(code: 0),
            .exited(code: 7),
            .signaled(signal: 15)
        ] {
            #expect(
                try TerminalLifecycle.running.transitioned(by: .processExited(status))
                    == .exited(status)
            )
        }
    }

    @Test("[TERM-STATE-001] Launch, read, write, and resize failures remain typed")
    func launchReadAndWriteFailuresRemainTyped() throws {
        #expect(
            try TerminalLifecycle.starting.transitioned(by: .ptyCreationFailed("pty"))
                == .failed(.ptyCreation(message: "pty"))
        )
        #expect(
            try TerminalLifecycle.starting.transitioned(by: .launchFailed("launch"))
                == .failed(.launch(message: "launch"))
        )
        #expect(
            try TerminalLifecycle.running.transitioned(by: .readFailed("read"))
                == .failed(.read(message: "read"))
        )
        #expect(
            try TerminalLifecycle.running.transitioned(by: .writeFailed("write"))
                == .failed(.write(message: "write"))
        )
        #expect(
            try TerminalLifecycle.running.transitioned(by: .resizeFailed("resize"))
                == .failed(.resize(message: "resize"))
        )
        #expect(TerminalFailure.read(message: "read").requiresProcessCleanup)
        #expect(TerminalFailure.write(message: "write").requiresProcessCleanup)
        #expect(TerminalFailure.resize(message: "resize").requiresProcessCleanup)
        #expect(!TerminalFailure.launch(message: "launch").requiresProcessCleanup)
    }

    @Test("[TERM-STATE-001] Fatal I/O failure remains visible after process cleanup")
    func fatalFailureReconcilesWithLaterProcessExit() throws {
        let failed = try TerminalLifecycle.running.transitioned(by: .readFailed("read"))
        #expect(
            try failed.transitioned(by: .processExited(.signaled(signal: 1))) == failed
        )
        #expect(!failed.acceptsInput)
    }

    @Test("[TERM-PROC-001] Close and immediate exit are valid while launch is still starting")
    func closeAndImmediateExitWhileStarting() throws {
        #expect(
            try TerminalLifecycle.starting.transitioned(by: .closeRequested) == .closing
        )
        #expect(
            try TerminalLifecycle.starting.transitioned(by: .processExited(.exited(code: 0)))
                == .exited(.exited(code: 0))
        )
    }

    @Test("[TERM-STATE-001] Illegal and stale transitions are refused")
    func illegalAndStaleTransitionsAreRefused() {
        #expect(throws: TerminalLifecycleTransitionError.self) {
            try TerminalLifecycle.running.transitioned(by: .launchSucceeded)
        }
        #expect(throws: TerminalLifecycleTransitionError.self) {
            try TerminalLifecycle.exited(.exited(code: 0)).transitioned(by: .closeRequested)
        }
    }
}

@Suite("Immutable terminal tabs state")
struct TerminalTabsStateTests {
    @Test("[TAB-001, TAB-003, TAB-005] Create, select, and close use independent IDs")
    func createSelectAndCloseUseIndependentInjectedIDs() throws {
        let firstID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let secondID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let thirdID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000003"))

        let one = try TerminalTabsState().creatingTab(id: firstID)
        #expect(one.tabs.map(\.id) == [firstID])
        #expect(one.tabs.map(\.title) == ["Local Shell"])
        #expect(one.selectedTabID == firstID)

        let three = try one.creatingTab(id: secondID).creatingTab(id: thirdID)
        #expect(three.tabs.map(\.id) == [firstID, secondID, thirdID])
        #expect(three.tabs.map(\.title) == ["Local Shell", "Local Shell 2", "Local Shell 3"])

        let selectedFirst = three.selectingTab(id: firstID)
        #expect(selectedFirst.selectedTabID == firstID)
        #expect(selectedFirst.selectingTab(id: UUID()).selectedTabID == firstID)

        let closedUnselected = selectedFirst.closingTab(id: thirdID)
        #expect(closedUnselected.selectedTabID == firstID)
        #expect(closedUnselected.tabs.map(\.id) == [firstID, secondID])

        let closedSelected = closedUnselected.closingTab(id: firstID)
        #expect(closedSelected.selectedTabID == secondID)
        #expect(closedSelected.tabs.map(\.id) == [secondID])
        let empty = closedSelected.closingTab(id: secondID)
        #expect(empty.selectedTabID == nil)
        #expect(empty.tabs.isEmpty)
    }

    @Test("[TAB-003] Duplicate identifiers are rejected")
    func duplicateIdentifiersAreRejected() throws {
        let id = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000004"))
        let state = try TerminalTabsState().creatingTab(id: id)
        #expect(throws: TerminalTabsStateError.duplicateIdentifier(id)) {
            try state.creatingTab(id: id)
        }
    }

    @Test("[TAB-005] Closing the selected last tab chooses its previous neighbor")
    func closingSelectedLastTabChoosesPreviousNeighbor() throws {
        let firstID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000011"))
        let secondID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000012"))
        let state = try TerminalTabsState().creatingTab(id: firstID).creatingTab(id: secondID)

        #expect(state.closingTab(id: secondID).selectedTabID == firstID)
    }

    @Test("[TAB-003, TERM-STATE-001] Lifecycle updates by ID and titles remain monotonic")
    func lifecycleUpdatesByIDAndLaterTitlesRemainMonotonic() throws {
        let firstID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000021"))
        let secondID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000022"))
        let exited = try TerminalTabsState()
            .creatingTab(id: firstID)
            .transitioningLifecycle(of: firstID, by: .startRequested)
            .transitioningLifecycle(of: firstID, by: .processExited(.exited(code: 0)))
        let state = try exited.creatingTab(id: secondID)

        #expect(state.tabs[0].lifecycle == .exited(.exited(code: 0)))
        #expect(state.tabs[1].title == "Local Shell 2")
    }

    @Test("[TERM-STATE-001] Untrusted dynamic titles are bounded and control-safe")
    func dynamicTitlesAreSanitizedAtTheTabBoundary() throws {
        let id = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000023"))
        let state = try TerminalTabsState().creatingTab(id: id)
        let sanitized = try state.updatingTitle(
            of: id,
            to: "\u{1B}\u{202E}   Hello\n世界  "
        )
        #expect(sanitized.tabs[0].title == "Hello 世界")

        let bounded = try sanitized.updatingTitle(
            of: id,
            to: String(repeating: "👩‍💻", count: 200)
        )
        #expect(bounded.tabs[0].title.count == TerminalTitlePolicy.maximumCharacterCount)

        let ignored = try bounded.updatingTitle(of: id, to: "\u{1B}\u{202E}\n")
        #expect(ignored.tabs[0].title == bounded.tabs[0].title)
    }
}

@Suite("Terminal shell resolution")
struct TerminalShellResolverTests {
    @Test("[TERM-PROC-001] Account, environment, and fallback shells are ordered")
    func usesAccountThenEnvironmentThenFallbackShell() throws {
        let executable = { (path: String) in
            path == "/account/fish" || path == "/env/bash" || path == "/bin/zsh"
        }
        let account = try TerminalShellResolver.resolve(
            accountShell: "/account/fish",
            environmentShell: "/env/bash",
            fallbackShell: "/bin/zsh",
            userHomeDirectory: "/Users/example",
            isUsableExecutableFile: executable
        )
        #expect(account.executablePath == "/account/fish")
        #expect(account.argumentZero == "-fish")
        #expect(account.arguments.isEmpty)
        #expect(account.workingDirectory == "/Users/example")

        let environment = try TerminalShellResolver.resolve(
            accountShell: "relative/fish",
            environmentShell: "/env/bash",
            fallbackShell: "/bin/zsh",
            userHomeDirectory: "/Users/example",
            isUsableExecutableFile: executable
        )
        #expect(environment.executablePath == "/env/bash")

        let fallback = try TerminalShellResolver.resolve(
            accountShell: "",
            environmentShell: "/missing/bash",
            fallbackShell: "/bin/zsh",
            userHomeDirectory: "/Users/example",
            isUsableExecutableFile: { $0 == "/bin/zsh" }
        )
        #expect(fallback.executablePath == "/bin/zsh")
        #expect(fallback.argumentZero == "-zsh")
        #expect(fallback.arguments.isEmpty)

        let directoryCandidate = try TerminalShellResolver.resolve(
            accountShell: "/account/directory",
            environmentShell: "/env/bash",
            fallbackShell: "/bin/zsh",
            userHomeDirectory: "/Users/example",
            isUsableExecutableFile: { $0 == "/env/bash" || $0 == "/bin/zsh" }
        )
        #expect(directoryCandidate.executablePath == "/env/bash")
    }

    @Test("[TERM-PROC-001] No executable candidate throws a typed error")
    func throwsTypedErrorWhenNoCandidateIsExecutable() {
        do {
            _ = try TerminalShellResolver.resolve(
                accountShell: nil,
                environmentShell: nil,
                fallbackShell: "/bin/zsh",
                userHomeDirectory: "/Users/example",
                isUsableExecutableFile: { _ in false }
            )
            Issue.record("Expected unavailable shell error")
        } catch {
            #expect(error as? TerminalShellResolutionError == .shellUnavailable)
        }
    }
}

@Suite("Terminal input routing")
struct TerminalInputRouterTests {
    @Test("[TERM-KEY-002] Required Control characters map to exact bytes")
    func requiredControlCharactersMapToExactBytes() {
        let expected: [(Character, UInt8)] = [
            ("C", 0x03), ("Z", 0x1A), ("D", 0x04), ("\\", 0x1C),
            ("V", 0x16), ("S", 0x13), ("Q", 0x11), ("L", 0x0C),
            ("R", 0x12), ("A", 0x01), ("E", 0x05), ("U", 0x15),
            ("K", 0x0B), ("W", 0x17), ("H", 0x08), ("I", 0x09),
            ("J", 0x0A), ("M", 0x0D), ("F", 0x06), ("T", 0x14),
            ("[", 0x1B), ("?", 0x7F)
        ]

        for (character, byte) in expected {
            #expect(
                TerminalInputRouter.route(key: .character(character), modifiers: [.control])
                    == .ptyBytes([byte])
            )
        }
    }

    @Test("[TERM-KEY-002] General Control mapping includes Shift-Control")
    func generalControlMappingAndShiftControl() {
        #expect(TerminalInputRouter.route(key: .character("a"), modifiers: [.control]) == .ptyBytes([0x01]))
        #expect(TerminalInputRouter.route(key: .character("@"), modifiers: [.control]) == .ptyBytes([0x00]))
        #expect(TerminalInputRouter.route(key: .character(" "), modifiers: [.control]) == .ptyBytes([0x00]))
        #expect(TerminalInputRouter.route(key: .character("_"), modifiers: [.control, .shift]) == .ptyBytes([0x1F]))
        #expect(TerminalInputRouter.route(key: .special, modifiers: [.control]) == .engine)
    }

    @Test("[TERM-KEY-002] Pre-encoded NSEvent Control scalars stay exact")
    func preEncodedControlScalarsStayExact() {
        for byte in UInt8(0x00)...UInt8(0x1F) {
            let character = Character(UnicodeScalar(byte))
            #expect(
                TerminalInputRouter.route(key: .character(character), modifiers: [.control])
                    == .ptyBytes([byte])
            )
        }
        #expect(
            TerminalInputRouter.route(
                key: .character(Character(UnicodeScalar(0x7F))),
                modifiers: [.control]
            ) == .ptyBytes([0x7F])
        )
    }

    @Test("[TERM-KEY-003] Command shortcuts stay local and emit no PTY bytes")
    func commandShortcutsAlwaysStayLocalAndEmitNoPTYBytes() {
        let expected: [(Character, TerminalLocalAction)] = [
            ("C", .copy), ("V", .paste), ("W", .closeTab), ("F", .find),
            ("T", .newTab), ("A", .selectAll)
        ]
        for (character, action) in expected {
            #expect(
                TerminalInputRouter.route(key: .character(character), modifiers: [.command])
                    == .local(action)
            )
        }
        #expect(
            TerminalInputRouter.route(key: .character("X"), modifiers: [.command])
                == .local(.unhandledCommand)
        )
        #expect(
            TerminalInputRouter.route(
                key: .character("W"),
                modifiers: [.command, .shift]
            ) == .local(.unhandledCommand),
            "Command-Shift-W is the distinct native Close Window command"
        )
    }

    @Test("[TERM-KEY-003] Only exact supported Command modifier sets trigger terminal actions")
    func modifiedCommandShortcutsRemainUnhandled() {
        #expect(
            TerminalInputRouter.route(
                key: .character("T"),
                modifiers: [.command, .shift]
            ) == .local(.unhandledCommand),
            "Command-Shift-T is reserved for reopen-closed-terminal behavior"
        )
        #expect(
            TerminalInputRouter.route(
                key: .character("W"),
                modifiers: [.command, .option]
            ) == .local(.unhandledCommand),
            "Option-Command-W must not masquerade as Close Terminal"
        )
        #expect(
            TerminalInputRouter.route(
                key: .character("C"),
                modifiers: [.command, .control]
            ) == .local(.unhandledCommand)
        )
        #expect(
            TerminalInputRouter.route(
                key: .character("W"),
                modifiers: [.command, .shift]
            ) == .local(.unhandledCommand),
            "Command-Shift-W remains available to the aggregate Close Window handler"
        )
    }
}

@Suite("Terminal paste policy")
struct TerminalPastePolicyTests {
    @Test("[TERM-CLIP-002] Line endings normalize without trimming or Return")
    func normalizesLineEndingsWithoutTrimmingOrAppendingReturn() throws {
        let payload = try TerminalPastePolicy.prepare("  one\r\ntwo\r三  ", bracketedPasteEnabled: false)

        #expect(payload.normalizedText == "  one\ntwo\n三  ")
        #expect(payload.isMultiline)
        #expect(payload.requiresConfirmation)
        #expect(payload.bytes == Array("  one\ntwo\n三  ".utf8))
    }

    @Test("[TERM-CLIP-002] Bracketed paste framing is deterministic and conditional")
    func bracketedPasteFramingIsDeterministicAndConditional() throws {
        let text = "測試"
        #expect(
            try TerminalPastePolicy.prepare(text, bracketedPasteEnabled: true).bytes
                == Array("\u{1B}[200~測試\u{1B}[201~".utf8)
        )
        #expect(try TerminalPastePolicy.prepare(text, bracketedPasteEnabled: false).bytes == Array(text.utf8))
        #expect(try TerminalPastePolicy.prepare("", bracketedPasteEnabled: false).bytes == [])
        #expect(try !TerminalPastePolicy.prepare("", bracketedPasteEnabled: false).isMultiline)
        #expect(try !TerminalPastePolicy.prepare(text, bracketedPasteEnabled: false).requiresConfirmation)
    }

    @Test("[TERM-CLIP-002, TERM-SEC-001] Unsafe paste payloads are rejected")
    func rejectsOversizedAndTerminatorInjection() {
        #expect(throws: TerminalPastePolicyError.payloadTooLarge(maximumBytes: 1_048_576)) {
            try TerminalPastePolicy.prepare(
                String(repeating: "x", count: 1_048_577),
                bracketedPasteEnabled: false
            )
        }
        #expect(throws: TerminalPastePolicyError.containsBracketedPasteTerminator) {
            try TerminalPastePolicy.prepare(
                "before\u{1B}[201~after",
                bracketedPasteEnabled: true
            )
        }
        #expect(throws: TerminalPastePolicyError.containsBidirectionalFormattingControl) {
            try TerminalPastePolicy.prepare(
                "echo safe\u{202E}txt",
                bracketedPasteEnabled: false
            )
        }
        #expect(throws: TerminalPastePolicyError.payloadTooLarge(maximumBytes: 1_048_576)) {
            try TerminalPastePolicy.prepare(
                String(repeating: "x", count: 1_048_576),
                bracketedPasteEnabled: true
            )
        }
    }

    @Test("[TERM-CLIP-002] Control content requires confirmation even when it is one line")
    func controlContentRequiresConfirmation() throws {
        let payload = try TerminalPastePolicy.prepare("echo\u{1B}[2J", bracketedPasteEnabled: false)
        #expect(payload.requiresConfirmation)
    }
}

@Suite("Terminal grid size")
struct TerminalGridSizeTests {
    @Test("[TERM-RESIZE-001] Grid sizes floor and clamp")
    func calculatesFloorsAndClampsGridDimensions() throws {
        #expect(
            try TerminalGridSize.calculating(
                pointWidth: 800,
                pointHeight: 400,
                cellWidth: 8,
                cellHeight: 16
            ) == TerminalGridSize(columns: 100, rows: 25)
        )
        #expect(
            try TerminalGridSize.calculating(
                pointWidth: 19.9,
                pointHeight: 39.9,
                cellWidth: 10,
                cellHeight: 10
            ) == TerminalGridSize(columns: 2, rows: 3)
        )
        #expect(
            try TerminalGridSize.calculating(
                pointWidth: 1,
                pointHeight: 1,
                cellWidth: 10,
                cellHeight: 10
            ) == TerminalGridSize(columns: 2, rows: 1)
        )
        #expect(
            try TerminalGridSize.calculating(
                pointWidth: Double.greatestFiniteMagnitude,
                pointHeight: Double.greatestFiniteMagnitude,
                cellWidth: 1,
                cellHeight: 1
            ) == TerminalGridSize(columns: .max, rows: .max)
        )
    }

    @Test("[TERM-RESIZE-001] Invalid and nonfinite dimensions throw typed failures")
    func invalidOrNonfiniteDimensionsThrowTypedFailure() {
        #expect(throws: TerminalGridSizeError.self) {
            try TerminalGridSize.calculating(
                pointWidth: .infinity,
                pointHeight: 100,
                cellWidth: 8,
                cellHeight: 16
            )
        }
        #expect(TerminalGridSize(columns: 0, rows: 0) == TerminalGridSize(columns: 2, rows: 1))
        #expect(throws: TerminalGridSizeError.self) {
            try TerminalGridSize.calculating(
                pointWidth: 100,
                pointHeight: 100,
                cellWidth: 0,
                cellHeight: 16
            )
        }
    }
}

@Suite("Terminal resize coalescing")
struct TerminalResizeCoalescingStateTests {
    @Test("[TERM-RESIZE-001] Coalescing suppresses unchanged sizes and emits latest once")
    func suppressesUnchangedRetainsLatestFiresOnceAndCancels() {
        let first = TerminalGridSize(columns: 80, rows: 24)
        let second = TerminalGridSize(columns: 100, rows: 30)
        let latest = TerminalGridSize(columns: 120, rows: 40)

        let initiallyPending = TerminalResizeCoalescingState().receiving(first)
        let firstFire = initiallyPending.firing()
        #expect(firstFire.emittedSize == first)
        #expect(firstFire.state.pendingSize == nil)

        #expect(firstFire.state.receiving(first).pendingSize == nil)
        let burst = firstFire.state.receiving(second).receiving(latest)
        #expect(burst.pendingSize == latest)

        let burstFire = burst.firing()
        #expect(burstFire.emittedSize == latest)
        #expect(burstFire.state.firing().emittedSize == nil)
        #expect(burst.receiving(second).cancelling().pendingSize == nil)

        let returnedToEmitted = firstFire.state.receiving(second).receiving(first)
        #expect(returnedToEmitted.pendingSize == nil)
        #expect(returnedToEmitted.firing().emittedSize == nil)
    }
}
