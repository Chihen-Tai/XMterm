import Foundation
import Testing
@testable import XMtermCore

@Suite("Session profile")
struct SessionProfileTests {
    @Test("A local profile round trips with explicit tagged JSON and stable metadata")
    func localProfileRoundTripsWithStableMetadata() throws {
        let profile = SessionProfile(
            id: SessionProfileID(rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!),
            name: "Local Terminal",
            favorite: true,
            createdAt: Date(timeIntervalSinceReferenceDate: 1_000),
            updatedAt: Date(timeIntervalSinceReferenceDate: 2_000),
            lastOpenedAt: Date(timeIntervalSinceReferenceDate: 3_000),
            sortOrder: 7,
            configuration: .local(
                LocalSessionProfile(
                    useLoginShell: true,
                    shellPath: nil,
                    workingDirectory: nil
                )
            )
        )

        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(SessionProfile.self, from: data)
        let json = try jsonObject(from: data)
        let local = try #require(json["local"] as? [String: Any])

        #expect(decoded == profile)
        #expect(decoded.id == profile.id)
        #expect(decoded.createdAt == profile.createdAt)
        #expect(decoded.updatedAt == profile.updatedAt)
        #expect(decoded.lastOpenedAt == profile.lastOpenedAt)
        #expect(decoded.favorite)
        #expect(decoded.sortOrder == 7)
        #expect(json["id"] as? String == "11111111-1111-1111-1111-111111111111")
        #expect(json["kind"] as? String == "local")
        #expect(json["ssh"] == nil)
        #expect(json["lastOpenedAt"] != nil)
        #expect(Set(local.keys) == ["useLoginShell", "shellPath", "workingDirectory"])
        #expect(local["shellPath"] is NSNull)
        #expect(local["workingDirectory"] is NSNull)
    }

    @Test("A custom local profile round trips with nonnil shell and working-directory paths")
    func customLocalProfileRoundTripsWithPaths() throws {
        let profile = makeProfile(
            configuration: .local(
                LocalSessionProfile(
                    useLoginShell: false,
                    shellPath: "/bin/zsh",
                    workingDirectory: "/Users/example/Projects"
                )
            )
        )

        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(SessionProfile.self, from: data)

        #expect(decoded == profile)
    }

    @Test("A direct SSH profile round trips with an ordinary identity-file path reference")
    func directSSHProfileRoundTripsWithIdentityPath() throws {
        let profile = makeProfile(
            configuration: .ssh(
                .direct(
                    host: "host.example.test",
                    port: 2222,
                    user: "example-user",
                    identityFilePath: "/Users/example/.ssh/id_test"
                )
            )
        )

        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(SessionProfile.self, from: data)
        let json = try jsonObject(from: data)
        let ssh = try #require(json["ssh"] as? [String: Any])

        #expect(decoded == profile)
        #expect(json["kind"] as? String == "ssh")
        #expect(json["local"] == nil)
        #expect(ssh["mode"] as? String == "direct")
        #expect(ssh["host"] as? String == "host.example.test")
        #expect(ssh["port"] as? Int == 2222)
        #expect(ssh["user"] as? String == "example-user")
        #expect(ssh["identityFilePath"] as? String == "/Users/example/.ssh/id_test")
        #expect(ssh["alias"] == nil)
    }

    @Test("An SSH config-alias profile round trips without direct fields")
    func configAliasProfileRoundTripsWithoutDirectFields() throws {
        let profile = makeProfile(configuration: .ssh(.configAlias(alias: "research-cluster")))

        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(SessionProfile.self, from: data)
        let json = try jsonObject(from: data)
        let ssh = try #require(json["ssh"] as? [String: Any])

        #expect(decoded == profile)
        #expect(ssh["mode"] as? String == "configAlias")
        #expect(ssh["alias"] as? String == "research-cluster")
        #expect(Set(ssh.keys) == ["mode", "alias"])
    }

    @Test("Encoded profiles never contain credential or private-key-content keys")
    func encodedProfilesContainNoCredentialKeys() throws {
        let profiles = [
            makeProfile(
                configuration: .local(
                    LocalSessionProfile(
                        useLoginShell: false,
                        shellPath: "/bin/zsh",
                        workingDirectory: "/Users/example/Projects"
                    )
                )
            ),
            makeProfile(
                configuration: .ssh(
                    .direct(
                        host: "host.example.test",
                        port: 22,
                        user: "example-user",
                        identityFilePath: "/Users/example/.ssh/id_test"
                    )
                )
            ),
            makeProfile(configuration: .ssh(.configAlias(alias: "research-cluster")))
        ]

        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profiles))
        let normalizedKeys = jsonKeys(in: object).map(normalizedKey)
        let forbiddenKeys: Set<String> = [
            "password",
            "otp",
            "passphrase",
            "privatekey",
            "privatekeycontent"
        ]

        #expect(forbiddenKeys.isDisjoint(with: normalizedKeys))
        #expect(normalizedKeys.contains("identityfilepath"))
    }

    @Test("Decoding rejects unknown and credential keys at every schema level")
    func decodingRejectsUnknownKeysAtEverySchemaLevel() throws {
        let localProfile = makeProfile(
            configuration: .local(
                LocalSessionProfile(
                    useLoginShell: true,
                    shellPath: nil,
                    workingDirectory: nil
                )
            )
        )
        let directProfile = makeProfile(
            configuration: .ssh(
                .direct(
                    host: "host.example.test",
                    port: 22,
                    user: "example-user",
                    identityFilePath: "/Users/example/.ssh/id_test"
                )
            )
        )
        let aliasProfile = makeProfile(
            configuration: .ssh(.configAlias(alias: "research-cluster"))
        )
        let fixtures: [(profile: SessionProfile, payload: String?, rejectedKey: String)] = [
            (localProfile, nil, "password"),
            (localProfile, nil, "futureTopLevelField"),
            (localProfile, "local", "otp"),
            (localProfile, "local", "futureLocalField"),
            (directProfile, "ssh", "passphrase"),
            (directProfile, "ssh", "privateKeyContent"),
            (directProfile, "ssh", "futureDirectField"),
            (aliasProfile, "ssh", "privateKeyContent"),
            (aliasProfile, "ssh", "futureAliasField")
        ]

        for fixture in fixtures {
            var json = try jsonObject(from: JSONEncoder().encode(fixture.profile))
            if let payloadKey = fixture.payload {
                var payload = try #require(json[payloadKey] as? [String: Any])
                payload[fixture.rejectedKey] = "must-not-be-accepted"
                json[payloadKey] = payload
            } else {
                json[fixture.rejectedKey] = "must-not-be-accepted"
            }
            let data = try JSONSerialization.data(withJSONObject: json)

            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(SessionProfile.self, from: data)
            }
        }
    }

    @Test("Decoding rejects missing and unknown profile discriminators")
    func decodingRejectsMissingAndUnknownDiscriminators() throws {
        let localProfile = makeProfile(
            configuration: .local(
                LocalSessionProfile(
                    useLoginShell: true,
                    shellPath: nil,
                    workingDirectory: nil
                )
            )
        )
        let directProfile = makeProfile(
            configuration: .ssh(
                .direct(
                    host: "host.example.test",
                    port: 22,
                    user: "example-user",
                    identityFilePath: nil
                )
            )
        )

        var missingKind = try jsonObject(from: JSONEncoder().encode(localProfile))
        missingKind.removeValue(forKey: "kind")
        var unknownKind = try jsonObject(from: JSONEncoder().encode(localProfile))
        unknownKind["kind"] = "futureKind"
        var missingMode = try jsonObject(from: JSONEncoder().encode(directProfile))
        var missingModePayload = try #require(missingMode["ssh"] as? [String: Any])
        missingModePayload.removeValue(forKey: "mode")
        missingMode["ssh"] = missingModePayload
        var unknownMode = try jsonObject(from: JSONEncoder().encode(directProfile))
        var unknownModePayload = try #require(unknownMode["ssh"] as? [String: Any])
        unknownModePayload["mode"] = "futureMode"
        unknownMode["ssh"] = unknownModePayload

        for json in [missingKind, unknownKind, missingMode, unknownMode] {
            let data = try JSONSerialization.data(withJSONObject: json)
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(SessionProfile.self, from: data)
            }
        }
    }

    @Test("Decoding rejects a profile with no payload for its explicit kind")
    func decodingRejectsMissingPayload() throws {
        var json = try jsonObject(
            from: JSONEncoder().encode(
                makeProfile(
                    configuration: .local(
                        LocalSessionProfile(
                            useLoginShell: true,
                            shellPath: nil,
                            workingDirectory: nil
                        )
                    )
                )
            )
        )
        json.removeValue(forKey: "local")
        let data = try JSONSerialization.data(withJSONObject: json)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SessionProfile.self, from: data)
        }
    }

    @Test("Decoding rejects contradictory local and SSH payloads")
    func decodingRejectsContradictoryProfilePayloads() throws {
        var json = try jsonObject(
            from: JSONEncoder().encode(
                makeProfile(
                    configuration: .local(
                        LocalSessionProfile(
                            useLoginShell: true,
                            shellPath: nil,
                            workingDirectory: nil
                        )
                    )
                )
            )
        )
        json["ssh"] = ["mode": "configAlias", "alias": "research-cluster"]
        let data = try JSONSerialization.data(withJSONObject: json)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SessionProfile.self, from: data)
        }
    }

    @Test("Decoding rejects SSH fields that contradict the explicit mode")
    func decodingRejectsContradictorySSHModePayload() throws {
        var json = try jsonObject(
            from: JSONEncoder().encode(
                makeProfile(
                    configuration: .ssh(
                        .direct(
                            host: "host.example.test",
                            port: 22,
                            user: "example-user",
                            identityFilePath: nil
                        )
                    )
                )
            )
        )
        var ssh = try #require(json["ssh"] as? [String: Any])
        ssh["alias"] = "research-cluster"
        json["ssh"] = ssh
        let data = try JSONSerialization.data(withJSONObject: json)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SessionProfile.self, from: data)
        }
    }

    @Test("Decoding rejects direct fields in a config-alias payload")
    func decodingRejectsDirectFieldsInConfigAliasPayload() throws {
        var json = try jsonObject(
            from: JSONEncoder().encode(
                makeProfile(configuration: .ssh(.configAlias(alias: "research-cluster")))
            )
        )
        var ssh = try #require(json["ssh"] as? [String: Any])
        ssh["host"] = "host.example.test"
        json["ssh"] = ssh
        let data = try JSONSerialization.data(withJSONObject: json)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SessionProfile.self, from: data)
        }
    }

    @Test("Editor drafts retain inactive fields for later field validation")
    func editorDraftRetainsModeAndRawFields() {
        let draft = SessionProfileDraft(
            name: "Research Cluster",
            favorite: true,
            kind: .ssh,
            local: LocalSessionProfileDraft(
                mode: .customShell,
                shellPath: "/bin/zsh",
                workingDirectory: "/Users/example/Projects"
            ),
            ssh: SSHSessionProfileDraft(
                mode: .configAlias,
                host: "inactive.example.test",
                port: "not-yet-validated",
                user: "inactive-user",
                sshConfigAlias: "research-cluster",
                identityFilePath: "/Users/example/.ssh/id_test"
            )
        )

        #expect(draft.kind == .ssh)
        #expect(draft.local.mode == .customShell)
        #expect(draft.ssh.mode == .configAlias)
        #expect(draft.ssh.port == "not-yet-validated")
        #expect(draft.ssh.identityFilePath == "/Users/example/.ssh/id_test")
    }

    private func makeProfile(configuration: SessionProfileConfiguration) -> SessionProfile {
        SessionProfile(
            id: SessionProfileID(rawValue: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!),
            name: "Example Profile",
            favorite: false,
            createdAt: Date(timeIntervalSinceReferenceDate: 10),
            updatedAt: Date(timeIntervalSinceReferenceDate: 20),
            lastOpenedAt: nil,
            sortOrder: 3,
            configuration: configuration
        )
    }

    private func jsonObject(from data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func jsonKeys(in value: Any) -> Set<String> {
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: Set(dictionary.keys)) { result, entry in
                result.formUnion(jsonKeys(in: entry.value))
            }
        }
        if let array = value as? [Any] {
            return array.reduce(into: []) { result, element in
                result.formUnion(jsonKeys(in: element))
            }
        }
        return []
    }

    private func normalizedKey(_ key: String) -> String {
        key.lowercased().filter(\.isLetter)
    }
}
