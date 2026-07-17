import Darwin
import Foundation
import Testing
import XMtermCore
@testable import XMtermTerminal

@Suite("Terminal session I/O failure reconciliation")
struct TerminalSessionIOFailureTests {
    @Test("[TAB-003] close disposition requires a known foreground job or live-query failure")
    func closeDispositionUsesLifecycleAndForegroundState() {
        #expect(
            TerminalSession.closeDisposition(
                lifecycle: .running,
                foregroundState: .shell
            ) == .closeImmediately
        )
        #expect(
            TerminalSession.closeDisposition(
                lifecycle: .running,
                foregroundState: .foregroundJob
            ) == .confirmForegroundJob
        )
        #expect(
            TerminalSession.closeDisposition(
                lifecycle: .running,
                foregroundState: .queryFailed(errorNumber: EIO)
            ) == .confirmUnknownForegroundActivity
        )
        #expect(
            TerminalSession.closeDisposition(
                lifecycle: .running,
                foregroundState: .terminalUnavailable
            ) == .closeImmediately
        )
        #expect(
            TerminalSession.closeDisposition(
                kind: .relaySSH,
                lifecycle: .running,
                foregroundState: .shell
            ) == .confirmSSHSession
        )

        for lifecycle in [
            TerminalLifecycle.starting,
            .closing,
            .exited(.exited(code: 0)),
            .failed(.launch(message: "fixture"))
        ] {
            #expect(
                TerminalSession.closeDisposition(
                    lifecycle: lifecycle,
                    foregroundState: .foregroundJob
                ) == .closeImmediately
            )
        }
    }

    @Test("Expected PTY close and hangup errors defer to child exit status")
    func expectedHangupsAwaitProcessExit() {
        let expectedHangups: [PTYControllerError] = [
            .closed,
            .writeFailed(errno: EIO),
            .writeFailed(errno: ENXIO),
            .resizeFailed(errno: EIO),
            .resizeFailed(errno: ENXIO)
        ]

        for error in expectedHangups {
            #expect(
                TerminalSession.ioFailureDisposition(for: error)
                    == .awaitProcessExit
            )
        }
    }

    @Test("Unexpected PTY write and resize errors remain fatal")
    func unexpectedIOErrorsRemainFatal() {
        #expect(
            TerminalSession.ioFailureDisposition(
                for: PTYControllerError.writeFailed(errno: ENOSPC)
            ) == .failSession
        )
        #expect(
            TerminalSession.ioFailureDisposition(
                for: PTYControllerError.resizeFailed(errno: EINVAL)
            ) == .failSession
        )
    }

    @Test("Session owns paste confirmation state and emits approved bytes once")
    @MainActor
    func pasteConfirmationRoutesThroughSession() throws {
        let session = TerminalSession(id: UUID())
        session.terminalView.acceptsInput = true
        var emittedBytes: [[UInt8]] = []
        session.terminalView.onBytesToPTY = { emittedBytes.append($0) }

        session.terminalView.paste(text: "first\nsecond")
        guard case let .paste(firstPrompt) = session.activeAlert else {
            Issue.record("Expected the session to own a multiline paste prompt")
            return
        }
        #expect(firstPrompt.lineCount == 2)
        #expect(firstPrompt.byteCount == 12)
        #expect(!firstPrompt.containsControlCharacters)

        session.resolvePasteAlert(approved: false)
        #expect(session.activeAlert == nil)
        #expect(emittedBytes.isEmpty)

        session.terminalView.paste(text: "first\nsecond")
        session.resolvePasteAlert(approved: true)
        session.resolvePasteAlert(approved: true)

        #expect(emittedBytes == [Array("first\nsecond".utf8)])
        #expect(session.activeAlert == nil)
    }

    @Test("Session forwards view metadata and finishes prelaunch cleanup once")
    @MainActor
    func viewCallbacksAndPrelaunchCleanupRemainDeterministic() {
        let session = TerminalSession(id: UUID())
        var observedTitle: String?
        var observedAction: TerminalLocalAction?
        var cleanupCount = 0
        session.onTitleChanged = { observedTitle = $0 }
        session.onLocalAction = { observedAction = $0 }
        session.onCleanupFinished = { cleanupCount += 1 }

        session.terminalView.onTitleChanged?("fixture-title")
        session.terminalView.onCurrentDirectoryChanged?("/fixture")
        session.terminalView.onLocalAction?(.find)
        session.terminalView.onPasteRejected?(.confirmationUnavailable)

        #expect(observedTitle == "fixture-title")
        #expect(session.currentDirectory == "/fixture")
        #expect(observedAction == .find)
        guard case let .error(alert) = session.activeAlert else {
            Issue.record("Expected a typed, user-facing terminal error")
            return
        }
        #expect(alert.message == "XMterm could not confirm this potentially unsafe paste.")

        session.dismissAlert()
        session.jumpToLatestOutput()
        session.requestClose()
        session.requestClose()

        #expect(session.activeAlert == nil)
        #expect(cleanupCount == 1)
    }
}
