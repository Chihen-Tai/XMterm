import Foundation
import Testing
@testable import XMtermCore

@Suite("Session profile validation")
struct SessionProfileValidationTests {
    @Test("Unicode names and surrounding whitespace normalize without changing supplied metadata")
    func unicodeNamesNormalizeWithDeterministicMetadata() throws {
        let id = profileID("11111111-1111-1111-1111-111111111111")
        let createdAt = Date(timeIntervalSinceReferenceDate: 100)
        let updatedAt = Date(timeIntervalSinceReferenceDate: 200)
        let lastOpenedAt = Date(timeIntervalSinceReferenceDate: 150)
        let draft = localDraft(name: "  終端 🌐  ")

        let profile = try SessionProfileValidator.validatedProfile(
            from: draft,
            id: id,
            createdAt: createdAt,
            updatedAt: updatedAt,
            lastOpenedAt: lastOpenedAt,
            sortOrder: 7
        )
        let duplicateName = try SessionProfileValidator.validatedProfile(
            from: draft,
            id: profileID("22222222-2222-2222-2222-222222222222"),
            createdAt: createdAt,
            updatedAt: updatedAt,
            lastOpenedAt: nil,
            sortOrder: 8
        )

        #expect(profile.name == "終端 🌐")
        #expect(duplicateName.name == profile.name)
        #expect(profile.id == id)
        #expect(profile.createdAt == createdAt)
        #expect(profile.updatedAt == updatedAt)
        #expect(profile.lastOpenedAt == lastOpenedAt)
        #expect(profile.sortOrder == 7)
    }

    @Test("Blank and C0/C1 control-bearing names report the stable name field")
    func blankAndControlBearingNamesAreRejected() throws {
        for name in ["   ", "bad\u{0}name", "bad\u{7F}name", "bad\u{85}name"] {
            let error = try #require(validationError {
                try validate(localDraft(name: name))
            })

            #expect(error.fields == [.name])
        }
    }

    @Test("Direct SSH trims fields and accepts both port boundaries")
    func directSSHNormalizesAndAcceptsPortBoundaries() throws {
        for port in ["1", "65535"] {
            let profile = try validate(
                sshDraft(
                    name: "  Relay  ",
                    mode: .direct,
                    host: "  relay.example.test  ",
                    port: "  \(port)  ",
                    user: "  alice  ",
                    identityFilePath: "  /Users/alice/.ssh/id_test  "
                )
            )

            #expect(profile.name == "Relay")
            #expect(
                profile.configuration == .ssh(
                    .direct(
                        host: "relay.example.test",
                        port: Int(port)!,
                        user: "alice",
                        identityFilePath: "/Users/alice/.ssh/id_test"
                    )
                )
            )
        }
    }

    @Test("Direct SSH reports host, port, and user errors independently")
    func directSSHReportsStableFieldErrors() throws {
        let error = try #require(validationError {
            try validate(
                sshDraft(
                    mode: .direct,
                    host: "bad host@example.test",
                    port: "not-a-port",
                    user: "-bad user@example.test"
                )
            )
        })

        #expect(error.fields == [.host, .port, .user])
        #expect(error.issues.contains(.init(field: .host, reason: .containsWhitespace)))
        #expect(error.issues.contains(.init(field: .host, reason: .containsAtSign)))
        #expect(error.issues.contains(.init(field: .port, reason: .invalidInteger)))
        #expect(error.issues.contains(.init(field: .user, reason: .startsWithHyphen)))
        #expect(error.issues.contains(.init(field: .user, reason: .containsWhitespace)))
        #expect(error.issues.contains(.init(field: .user, reason: .containsAtSign)))

        for port in ["0", "65536"] {
            let boundaryError = try #require(validationError {
                try validate(sshDraft(mode: .direct, port: port))
            })
            #expect(
                boundaryError.issues == [
                    .init(field: .port, reason: .outOfRange)
                ]
            )
        }

        let blankFields = try #require(validationError {
            try validate(sshDraft(mode: .direct, host: "   ", user: "   "))
        })
        #expect(blankFields.issues.contains(.init(field: .host, reason: .required)))
        #expect(blankFields.issues.contains(.init(field: .user, reason: .required)))

        let controlFields = try #require(validationError {
            try validate(
                sshDraft(
                    mode: .direct,
                    host: "host\u{0}.example.test",
                    user: "user\u{85}name"
                )
            )
        })
        #expect(
            controlFields.issues.contains(
                .init(field: .host, reason: .containsControlCharacter)
            )
        )
        #expect(
            controlFields.issues.contains(
                .init(field: .user, reason: .containsControlCharacter)
            )
        )
    }

    @Test("Direct SSH treats a blank identity path as absent and rejects relative paths")
    func directSSHIdentityPathIsStructurallyValidated() throws {
        let withoutIdentity = try validate(
            sshDraft(mode: .direct, identityFilePath: "   ")
        )
        #expect(
            withoutIdentity.configuration == .ssh(
                .direct(host: "host.example.test", port: 22, user: "user", identityFilePath: nil)
            )
        )

        let error = try #require(validationError {
            try validate(
                sshDraft(mode: .direct, identityFilePath: ".ssh/id_test")
            )
        })
        #expect(
            error.issues == [
                .init(field: .identityFilePath, reason: .mustBeAbsolutePath)
            ]
        )
    }

    @Test("Trimming never hides C0/C1 controls in ports or optional paths")
    func controlsCannotDisappearDuringNormalization() throws {
        let directError = try #require(validationError {
            try validate(
                sshDraft(
                    mode: .direct,
                    port: "22\n",
                    identityFilePath: "\n"
                )
            )
        })
        #expect(
            directError.issues.contains(
                .init(field: .port, reason: .containsControlCharacter)
            )
        )
        #expect(
            directError.issues.contains(
                .init(field: .identityFilePath, reason: .containsControlCharacter)
            )
        )

        let localError = try #require(validationError {
            try validate(localDraft(workingDirectory: "\u{85}"))
        })
        #expect(
            localError.issues == [
                .init(field: .workingDirectory, reason: .containsControlCharacter)
            ]
        )
    }

    @Test("Config alias mode is authoritative and omits retained direct draft fields")
    func configAliasModeOmitsInactiveDirectFields() throws {
        let profile = try validate(
            sshDraft(
                mode: .configAlias,
                host: "invalid host@ignored",
                port: "ignored",
                user: "-ignored",
                alias: "  research-cluster  ",
                identityFilePath: "relative/ignored"
            )
        )

        #expect(profile.configuration == .ssh(.configAlias(alias: "research-cluster")))
    }

    @Test("Config aliases reject blank, whitespace, controls, and option-shaped values")
    func invalidConfigAliasesAreRejected() throws {
        let fixtures: [(String, SessionProfileValidationReason)] = [
            ("   ", .required),
            ("research cluster", .containsWhitespace),
            ("research\u{1B}cluster", .containsControlCharacter),
            ("-research", .startsWithHyphen)
        ]

        for (alias, reason) in fixtures {
            let error = try #require(validationError {
                try validate(sshDraft(mode: .configAlias, alias: alias))
            })
            #expect(error.issues.contains(.init(field: .sshConfigAlias, reason: reason)))
        }
    }

    @Test("Login-shell mode omits its inactive shell path and normalizes an absolute working directory")
    func loginShellOmitsInactiveShellPath() throws {
        let profile = try validate(
            localDraft(
                mode: .loginShell,
                shellPath: "relative/ignored",
                workingDirectory: "  /Users/example/Projects  "
            )
        )

        #expect(
            profile.configuration == .local(
                LocalSessionProfile(
                    useLoginShell: true,
                    shellPath: nil,
                    workingDirectory: "/Users/example/Projects"
                )
            )
        )
    }

    @Test("Custom-shell and working-directory paths are required or absolute as appropriate")
    func customShellAndWorkingDirectoryAreStructurallyValidated() throws {
        let missingShell = try #require(validationError {
            try validate(localDraft(mode: .customShell, shellPath: "   "))
        })
        #expect(missingShell.issues == [.init(field: .shellPath, reason: .required)])

        let relativePaths = try #require(validationError {
            try validate(
                localDraft(
                    mode: .customShell,
                    shellPath: "bin/zsh",
                    workingDirectory: "Projects"
                )
            )
        })
        #expect(relativePaths.fields == [.shellPath, .workingDirectory])
        #expect(
            relativePaths.issues.contains(
                .init(field: .shellPath, reason: .mustBeAbsolutePath)
            )
        )
        #expect(
            relativePaths.issues.contains(
                .init(field: .workingDirectory, reason: .mustBeAbsolutePath)
            )
        )

        let custom = try validate(
            localDraft(
                mode: .customShell,
                shellPath: "  /opt/homebrew/bin/fish  ",
                workingDirectory: "   "
            )
        )
        #expect(
            custom.configuration == .local(
                LocalSessionProfile(
                    useLoginShell: false,
                    shellPath: "/opt/homebrew/bin/fish",
                    workingDirectory: nil
                )
            )
        )
    }

    @Test("Decoded profiles receive structural validation without checking path existence")
    func decodedProfilesAreValidatedWithoutFilesystemChecks() throws {
        let missingButStructurallyValid = SessionProfile(
            id: profileID("33333333-3333-3333-3333-333333333333"),
            name: "Missing Local Paths",
            favorite: true,
            createdAt: Date(timeIntervalSinceReferenceDate: 300),
            updatedAt: Date(timeIntervalSinceReferenceDate: 400),
            lastOpenedAt: Date(timeIntervalSinceReferenceDate: 350),
            sortOrder: 9,
            configuration: .local(
                LocalSessionProfile(
                    useLoginShell: false,
                    shellPath: "/definitely/not/present/xmterm-shell",
                    workingDirectory: "/definitely/not/present/xmterm-directory"
                )
            )
        )

        let validated = try SessionProfileValidator.validatedProfile(missingButStructurallyValid)

        #expect(validated == missingButStructurallyValid)
    }

    @Test("Decoded profiles reject noncanonical stored strings instead of repairing them")
    func decodedProfilesRejectNoncanonicalStoredStrings() throws {
        let fixtures: [(SessionProfileValidationField, SessionProfile)] = [
            (
                .name,
                decodedProfile(
                    name: "  Padded Name  ",
                    configuration: .ssh(.configAlias(alias: "canonical-alias"))
                )
            ),
            (
                .sshConfigAlias,
                decodedProfile(
                    configuration: .ssh(.configAlias(alias: "  padded-alias  "))
                )
            ),
            (
                .host,
                decodedProfile(
                    configuration: .ssh(
                        .direct(
                            host: "  host.example.test  ",
                            port: 22,
                            user: "user",
                            identityFilePath: nil
                        )
                    )
                )
            ),
            (
                .user,
                decodedProfile(
                    configuration: .ssh(
                        .direct(
                            host: "host.example.test",
                            port: 22,
                            user: "  user  ",
                            identityFilePath: nil
                        )
                    )
                )
            ),
            (
                .identityFilePath,
                decodedProfile(
                    configuration: .ssh(
                        .direct(
                            host: "host.example.test",
                            port: 22,
                            user: "user",
                            identityFilePath: "  /not/present/id_test  "
                        )
                    )
                )
            ),
            (
                .shellPath,
                decodedProfile(
                    configuration: .local(
                        LocalSessionProfile(
                            useLoginShell: false,
                            shellPath: "  /not/present/shell  ",
                            workingDirectory: nil
                        )
                    )
                )
            ),
            (
                .workingDirectory,
                decodedProfile(
                    configuration: .local(
                        LocalSessionProfile(
                            useLoginShell: true,
                            shellPath: nil,
                            workingDirectory: "  /not/present/directory  "
                        )
                    )
                )
            )
        ]

        for (field, profile) in fixtures {
            let error = try #require(validationError {
                try SessionProfileValidator.validatedProfile(profile)
            })
            #expect(
                error.issues == [
                    .init(field: field, reason: .mustBeCanonical)
                ]
            )
        }
    }

    @Test("Decoded login-shell profiles reject a persisted custom shell field")
    func decodedLoginShellRejectsContradictoryShellPath() throws {
        let profile = SessionProfile(
            id: profileID("34343434-3434-3434-3434-343434343434"),
            name: "Contradictory Login Shell",
            favorite: false,
            createdAt: Date(timeIntervalSinceReferenceDate: 10),
            updatedAt: Date(timeIntervalSinceReferenceDate: 20),
            lastOpenedAt: nil,
            sortOrder: 1,
            configuration: .local(
                LocalSessionProfile(
                    useLoginShell: true,
                    shellPath: "/bin/zsh",
                    workingDirectory: nil
                )
            )
        )

        let error = try #require(validationError {
            try SessionProfileValidator.validatedProfile(profile)
        })

        #expect(
            error.issues == [
                .init(field: .shellPath, reason: .contradictsSelectedMode)
            ]
        )
    }

    @Test("Decoded invalid profiles report the same stable fields as drafts")
    func decodedInvalidProfilesReportStableFields() throws {
        let profile = SessionProfile(
            id: profileID("44444444-4444-4444-4444-444444444444"),
            name: "Decoded SSH",
            favorite: false,
            createdAt: Date(timeIntervalSinceReferenceDate: 10),
            updatedAt: Date(timeIntervalSinceReferenceDate: 20),
            lastOpenedAt: nil,
            sortOrder: 1,
            configuration: .ssh(
                .direct(host: "bad host", port: 70_000, user: "-user", identityFilePath: "relative")
            )
        )

        let error = try #require(validationError {
            try SessionProfileValidator.validatedProfile(profile)
        })

        #expect(error.fields == [.host, .port, .user, .identityFilePath])
    }

    private func validate(_ draft: SessionProfileDraft) throws -> SessionProfile {
        try SessionProfileValidator.validatedProfile(
            from: draft,
            id: profileID("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"),
            createdAt: Date(timeIntervalSinceReferenceDate: 10),
            updatedAt: Date(timeIntervalSinceReferenceDate: 20),
            lastOpenedAt: nil,
            sortOrder: 3
        )
    }

    private func decodedProfile(
        name: String = "Canonical Profile",
        configuration: SessionProfileConfiguration
    ) -> SessionProfile {
        SessionProfile(
            id: profileID("45454545-4545-4545-4545-454545454545"),
            name: name,
            favorite: false,
            createdAt: Date(timeIntervalSinceReferenceDate: 10),
            updatedAt: Date(timeIntervalSinceReferenceDate: 20),
            lastOpenedAt: nil,
            sortOrder: 1,
            configuration: configuration
        )
    }

    private func validationError(
        _ operation: () throws -> SessionProfile
    ) -> SessionProfileValidationError? {
        do {
            _ = try operation()
            Issue.record("Expected structural validation to fail")
            return nil
        } catch let error as SessionProfileValidationError {
            return error
        } catch {
            Issue.record("Expected SessionProfileValidationError, received \(error)")
            return nil
        }
    }

    private func localDraft(
        name: String = "Local Terminal",
        mode: LocalSessionProfileDraftMode = .loginShell,
        shellPath: String = "",
        workingDirectory: String = ""
    ) -> SessionProfileDraft {
        SessionProfileDraft(
            name: name,
            favorite: false,
            kind: .local,
            local: LocalSessionProfileDraft(
                mode: mode,
                shellPath: shellPath,
                workingDirectory: workingDirectory
            ),
            ssh: SSHSessionProfileDraft(
                mode: .direct,
                host: "inactive",
                port: "22",
                user: "inactive",
                sshConfigAlias: "",
                identityFilePath: ""
            )
        )
    }

    private func sshDraft(
        name: String = "SSH Session",
        mode: SSHSessionProfileDraftMode,
        host: String = "host.example.test",
        port: String = "22",
        user: String = "user",
        alias: String = "research-cluster",
        identityFilePath: String = ""
    ) -> SessionProfileDraft {
        SessionProfileDraft(
            name: name,
            favorite: false,
            kind: .ssh,
            local: LocalSessionProfileDraft(
                mode: .loginShell,
                shellPath: "",
                workingDirectory: ""
            ),
            ssh: SSHSessionProfileDraft(
                mode: mode,
                host: host,
                port: port,
                user: user,
                sshConfigAlias: alias,
                identityFilePath: identityFilePath
            )
        )
    }

    private func profileID(_ value: String) -> SessionProfileID {
        SessionProfileID(rawValue: UUID(uuidString: value)!)
    }
}
