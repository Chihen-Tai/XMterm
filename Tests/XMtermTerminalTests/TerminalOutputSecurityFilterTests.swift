import Foundation
import Testing
@testable import XMtermTerminal

@Suite("Terminal output security filter")
struct TerminalOutputSecurityFilterTests {
    @Test("Plain UTF-8 and bounded CSI output pass unchanged across chunks")
    func ordinaryOutputPassesUnchanged() {
        var filter = TerminalOutputSecurityFilter()
        let first = Array("XMterm 測".utf8) + Array("\u{1B}[38;5;123m".utf8)
        let second = Array("試 🧪\u{1B}[0m\r\n".utf8)

        let output = filter.process(first) + filter.process(second)

        #expect(output == first + second)
        #expect(filter.bufferedByteCount == 0)
    }

    @Test("OSC, APC, DCS, PM, and SOS payloads never reach the terminal engine")
    func terminalControlStringsAreDroppedAcrossChunks() {
        let sequences = [
            "\u{1B}]1337;File=name=dGVzdA==:cGF5bG9hZA==\u{7}",
            "\u{1B}_Gf=100,t=t;L3RtcC94bXRlcm0tdGVzdA==\u{1B}\\",
            "\u{1B}Pq!999999999~\u{1B}\\",
            "\u{1B}^private-message\u{1B}\\",
            "\u{1B}Xstart-of-string\u{1B}\\"
        ]

        for sequence in sequences {
            var filter = TerminalOutputSecurityFilter()
            let bytes = Array(("before" + sequence + "after").utf8)
            let split = bytes.count / 2
            let output = filter.process(Array(bytes[..<split]))
                + filter.process(Array(bytes[split...]))

            #expect(String(decoding: output, as: UTF8.self) == "beforeafter")
            #expect(filter.bufferedByteCount == 0)
        }
    }

    @Test("C1 control-string forms are dropped without corrupting valid UTF-8")
    func c1ControlStringsAreDropped() {
        let validUnicode = Array("œ測試".utf8)
        for introducer: UInt8 in [0x90, 0x98, 0x9D, 0x9E, 0x9F] {
            var filter = TerminalOutputSecurityFilter()
            let unsafe = [introducer] + Array("52;c;secret".utf8) + [0x9C]
            let output = filter.process(validUnicode + unsafe + validUnicode)
            #expect(output == validUnicode + validUnicode)
        }
    }

    @Test("Oversized and overflow-shaped CSI parameters are discarded with bounded memory")
    func oversizedCSIIsDiscarded() {
        var filter = TerminalOutputSecurityFilter()
        let longParameter = "\u{1B}[" + String(repeating: "9", count: 10_000) + "m"

        let output = filter.process(Array(("before" + longParameter + "after").utf8))

        #expect(String(decoding: output, as: UTF8.self) == "beforeafter")
        #expect(filter.bufferedByteCount <= TerminalOutputSecurityFilter.maximumBufferedBytes)
    }

    @Test("Window operations and resource-amplifying CSI parameters are rejected")
    func semanticCSIAmplificationIsRejected() {
        var filter = TerminalOutputSecurityFilter()
        let unsafe = "\u{1B}[22;0t\u{1B}[999999999L"

        let output = filter.process(Array(("before" + unsafe + "after").utf8))

        #expect(String(decoding: output, as: UTF8.self) == "beforeafter")
        #expect(filter.bufferedByteCount == 0)
    }

    @Test("CSI commands that trigger unconditional upstream logging are rejected")
    func outputTriggeredLoggingCommandsAreRejected() {
        var filter = TerminalOutputSecurityFilter()
        let unsafe = "\u{1B}[999m\u{1B}[1;'z\u{1B}[?1016h\u{1B}[?1016l"
        let safe = "\u{1B}[1;31m\u{1B}[38;2;255;0;128m\u{1B}[0m"

        let output = filter.process(Array(("before" + unsafe + safe + "after").utf8))

        #expect(String(decoding: output, as: UTF8.self) == "before" + safe + "after")
    }

    @Test("Filtering is invariant across every possible chunk split")
    func everyChunkSplitProducesTheSameSafeOutput() {
        let input = Array(
            "前\u{1B}[31m景\u{1B}]52;c;secret\u{7}\u{1B}_Gf=100;payload\u{1B}\\\u{1B}[0m後"
                .utf8
        )
        var wholeFilter = TerminalOutputSecurityFilter()
        let expected = wholeFilter.process(input)

        for split in 0...input.count {
            var splitFilter = TerminalOutputSecurityFilter()
            let output = splitFilter.process(Array(input[..<split]))
                + splitFilter.process(Array(input[split...]))
            #expect(output == expected, "Mismatch at byte split \(split)")
        }

        var bytewiseFilter = TerminalOutputSecurityFilter()
        let bytewiseOutput = input.flatMap { bytewiseFilter.process([$0]) }
        #expect(bytewiseOutput == expected)
    }

    @Test("Cancellation and terminators recover without leaking discarded content")
    func cancellationAndTerminatorsRecover() {
        let recoveryCases: [[UInt8]] = [
            Array("\u{1B}]drop".utf8) + [0x07],
            Array("\u{1B}_drop\u{1B}\\".utf8),
            Array("\u{1B}Pdrop".utf8) + [0x18],
            Array("\u{1B}^drop".utf8) + [0x1A],
            [0x9D] + Array("drop".utf8) + [0x9C]
        ]

        for sequence in recoveryCases {
            var filter = TerminalOutputSecurityFilter()
            let output = filter.process(Array("before".utf8) + sequence + Array("after".utf8))
            #expect(String(decoding: output, as: UTF8.self) == "beforeafter")
            #expect(filter.bufferedByteCount == 0)
        }
    }

    @Test("An unterminated control string retains no payload bytes")
    func unterminatedControlStringUsesConstantMemory() {
        var filter = TerminalOutputSecurityFilter()
        let prefix = Array("\u{1B}]1337;File=:".utf8)

        _ = filter.process(prefix + [UInt8](repeating: 0x41, count: 1_000_000))

        #expect(filter.bufferedByteCount == 0)
        #expect(filter.isDiscardingControlString)
        #expect(filter.process(Array("still discarded".utf8)).isEmpty)
        #expect(filter.process([0x07]) == [])
        #expect(filter.process(Array("visible".utf8)) == Array("visible".utf8))
    }
}
