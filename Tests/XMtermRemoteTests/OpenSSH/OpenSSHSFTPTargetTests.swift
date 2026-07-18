import Testing
import XMtermCore
@testable import XMtermRemote

@Suite("System OpenSSH SFTP subsystem launch")
struct OpenSSHSFTPTargetTests {
    @Test("[SESS-004, FILE-XFER-004] Relay direct target produces exact noninteractive subsystem argv")
    func relayArgumentsAreExact() throws {
        let target = try OpenSSHSFTPTarget(
            profile: .direct(
                host: "140.109.226.155",
                port: 54_426,
                user: "allen921103",
                identityFilePath: nil
            )
        )

        #expect(target.executablePath == "/usr/bin/ssh")
        #expect(
            target.arguments == [
                "-T",
                "-o", "BatchMode=yes",
                "-s",
                "-p", "54426",
                "allen921103@140.109.226.155",
                "sftp"
            ]
        )
    }

    @Test("[SESS-004, FILE-XFER-004] identity path and alias remain separate argv values")
    func identityAndAliasArgumentsAreExact() throws {
        let direct = try OpenSSHSFTPTarget(
            profile: .direct(
                host: "example.test",
                port: 22,
                user: "user",
                identityFilePath: "/tmp/key with spaces"
            )
        )
        #expect(
            direct.arguments == [
                "-T",
                "-o", "BatchMode=yes",
                "-i", "/tmp/key with spaces",
                "-s",
                "-p", "22",
                "user@example.test",
                "sftp"
            ]
        )

        let alias = try OpenSSHSFTPTarget(profile: .configAlias(alias: "relay-via-jump"))
        #expect(
            alias.arguments == [
                "-T",
                "-o", "BatchMode=yes",
                "-s",
                "relay-via-jump",
                "sftp"
            ]
        )
    }

    @Test("[SESS-004, FILE-XFER-004] invalid or option-shaped target values fail before Process")
    func invalidTargetsFailClosed() {
        #expect(throws: OpenSSHSFTPTargetError.invalidHost) {
            try OpenSSHSFTPTarget(
                profile: .direct(host: "bad host", port: 22, user: "user", identityFilePath: nil)
            )
        }
        #expect(throws: OpenSSHSFTPTargetError.invalidUser) {
            try OpenSSHSFTPTarget(
                profile: .direct(host: "host", port: 22, user: "-root", identityFilePath: nil)
            )
        }
        #expect(throws: OpenSSHSFTPTargetError.invalidPort(0)) {
            try OpenSSHSFTPTarget(
                profile: .direct(host: "host", port: 0, user: "user", identityFilePath: nil)
            )
        }
        #expect(throws: OpenSSHSFTPTargetError.invalidIdentityFilePath) {
            try OpenSSHSFTPTarget(
                profile: .direct(host: "host", port: 22, user: "user", identityFilePath: "key")
            )
        }
        #expect(throws: OpenSSHSFTPTargetError.invalidAlias) {
            try OpenSSHSFTPTarget(profile: .configAlias(alias: "-oProxyCommand=bad"))
        }
    }

    @Test("[FILE-STATE-001] production transport failures map to stable bounded categories")
    func mapsTypedFailures() {
        let expectations: [(OpenSSHSFTPFailure, RemoteFileError.Category)] = [
            (.authenticationRequired, .authenticationRequired),
            (.hostKeyVerificationFailed, .hostKeyVerificationFailed),
            (.interactiveAuthenticationUnsupported, .interactiveAuthenticationUnsupported),
            (.permissionDenied, .permissionDenied),
            (.pathNotFound, .pathNotFound),
            (.unsupportedProtocol, .unsupportedProtocol),
            (.cancelled, .cancelled),
            (.timeout, .timeout),
            (.malformedResponse, .malformedResponse),
            (.transportUnavailable, .transportUnavailable),
            (.limitExceeded, .limitExceeded),
            (.unknown, .unknown)
        ]

        for (failure, expectedCategory) in expectations {
            let error = failure.remoteFileError
            #expect(error.category == expectedCategory)
            #expect(!error.userFacingMessage.isEmpty)
            #expect(error.userFacingMessage.utf8.count <= RemoteFileError.maximumUserFacingMessageByteCount)
        }
    }
}
