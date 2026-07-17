import Foundation
import Testing
@testable import XMtermCore

@Suite("Session profile collection")
struct SessionProfileCollectionTests {
    @Test("Empty collections are valid initialized state and never seed implicitly")
    func emptyCollectionsRemainEmpty() throws {
        let empty = SessionProfileCollection()
        let reconstructed = try SessionProfileCollection(profiles: empty.profiles)

        #expect(empty.profiles.isEmpty)
        #expect(reconstructed.profiles.isEmpty)
        requireSendable(empty)
    }

    @Test("The explicit built-in factory creates exactly the two specified deterministic defaults")
    func builtInDefaultsUseCallerSuppliedIdentityAndDate() throws {
        let localID = profileID("10000000-0000-0000-0000-000000000001")
        let relayID = profileID("10000000-0000-0000-0000-000000000002")
        let seedDate = Date(timeIntervalSinceReferenceDate: 1_000)

        let defaults = try SessionProfileCollection.builtInDefaults(
            localID: localID,
            relayID: relayID,
            seedDate: seedDate
        )
        let repeated = try SessionProfileCollection.builtInDefaults(
            localID: localID,
            relayID: relayID,
            seedDate: seedDate
        )

        #expect(defaults == repeated)
        #expect(defaults.profiles.map(\.id) == [localID, relayID])
        #expect(defaults.profiles.map(\.name) == ["Local Terminal", "Relay Host"])
        #expect(defaults.profiles.map(\.sortOrder) == [0, 1])
        #expect(defaults.profiles.allSatisfy { !$0.favorite && $0.lastOpenedAt == nil })
        #expect(defaults.profiles.allSatisfy { $0.createdAt == seedDate && $0.updatedAt == seedDate })
        #expect(
            defaults.profiles[0].configuration == .local(
                LocalSessionProfile(
                    useLoginShell: true,
                    shellPath: nil,
                    workingDirectory: nil
                )
            )
        )
        #expect(
            defaults.profiles[1].configuration == .ssh(
                .direct(
                    host: "140.109.226.155",
                    port: 54_426,
                    user: "allen921103",
                    identityFilePath: nil
                )
            )
        )

        #expect(
            throws: SessionProfileCollectionError.duplicateIdentifier(localID)
        ) {
            try SessionProfileCollection.builtInDefaults(
                localID: localID,
                relayID: localID,
                seedDate: seedDate
            )
        }
    }

    @Test("Construction and insertion reject duplicate IDs with a typed error")
    func duplicateIDsAreRejected() throws {
        let profile = makeProfile(
            id: profileID("20000000-0000-0000-0000-000000000001"),
            name: "One",
            sortOrder: 0
        )

        #expect(
            throws: SessionProfileCollectionError.duplicateIdentifier(profile.id)
        ) {
            try SessionProfileCollection(profiles: [profile, profile])
        }

        let collection = try SessionProfileCollection(profiles: [profile])
        #expect(
            throws: SessionProfileCollectionError.duplicateIdentifier(profile.id)
        ) {
            try collection.inserting(profile)
        }
    }

    @Test("Create appends normalized local and SSH profiles with stable IDs and next sort order")
    func createSupportsCoexistingLocalAndSSHProfilesWithoutMutatingPriorValues() throws {
        let empty = SessionProfileCollection()
        let localID = profileID("30000000-0000-0000-0000-000000000001")
        let sshID = profileID("30000000-0000-0000-0000-000000000002")
        let localCreatedAt = Date(timeIntervalSinceReferenceDate: 100)
        let sshCreatedAt = Date(timeIntervalSinceReferenceDate: 200)

        let localOnly = try empty.creating(
            from: localDraft(name: "  Local Work  "),
            id: localID,
            createdAt: localCreatedAt,
            updatedAt: localCreatedAt
        )
        let both = try localOnly.creating(
            from: sshDraft(name: "  Research SSH  "),
            id: sshID,
            createdAt: sshCreatedAt,
            updatedAt: sshCreatedAt
        )

        #expect(empty.profiles.isEmpty)
        #expect(localOnly.profiles.map(\.id) == [localID])
        #expect(both.profiles.map(\.id) == [localID, sshID])
        #expect(both.profiles.map(\.name) == ["Local Work", "Research SSH"])
        #expect(both.profiles.map(\.sortOrder) == [0, 1])
        #expect(both.profiles[0].configuration.isLocal)
        #expect(both.profiles[1].configuration.isSSH)
    }

    @Test("Construction rejects a noncanonical decoded profile")
    func constructionRejectsNoncanonicalProfiles() throws {
        let input = makeProfile(
            id: profileID("30500000-0000-0000-0000-000000000001"),
            name: "  Imported Profile  ",
            sortOrder: 4
        )

        let error = try #require(collectionValidationError {
            try SessionProfileCollection(profiles: [input])
        })

        #expect(error.issues == [.init(field: .name, reason: .mustBeCanonical)])
    }

    @Test("Insertion rejects noncanonical input instead of normalizing it")
    func insertionRejectsNoncanonicalInput() throws {
        let input = makeProfile(
            id: profileID("31000000-0000-0000-0000-000000000001"),
            name: "Imported Alias",
            sortOrder: 4,
            configuration: .ssh(.configAlias(alias: "  imported-host  "))
        )

        let error = try #require(collectionValidationError {
            try SessionProfileCollection().inserting(input)
        })

        #expect(input.configuration == .ssh(.configAlias(alias: "  imported-host  ")))
        #expect(
            error.issues == [
                .init(field: .sshConfigAlias, reason: .mustBeCanonical)
            ]
        )
    }

    @Test("Edit and rename preserve identity, creation, recency, and ordering")
    func editAndRenamePreserveStableMetadataAndAllowDuplicateNames() throws {
        let originalID = profileID("40000000-0000-0000-0000-000000000001")
        let siblingID = profileID("40000000-0000-0000-0000-000000000002")
        let createdAt = Date(timeIntervalSinceReferenceDate: 100)
        let lastOpenedAt = Date(timeIntervalSinceReferenceDate: 150)
        let original = makeProfile(
            id: originalID,
            name: "Original",
            favorite: true,
            createdAt: createdAt,
            updatedAt: Date(timeIntervalSinceReferenceDate: 160),
            lastOpenedAt: lastOpenedAt,
            sortOrder: 5,
            configuration: .local(
                LocalSessionProfile(useLoginShell: true, shellPath: nil, workingDirectory: nil)
            )
        )
        let sibling = makeProfile(id: siblingID, name: "Shared Name", sortOrder: 6)
        let collection = try SessionProfileCollection(profiles: [original, sibling])
        let editDate = Date(timeIntervalSinceReferenceDate: 200)

        let edited = try collection.editing(
            id: originalID,
            with: sshDraft(name: "  Edited Alias  ", favorite: false, mode: .configAlias),
            updatedAt: editDate
        )
        let renameDate = Date(timeIntervalSinceReferenceDate: 250)
        let renamed = try edited.renaming(
            id: originalID,
            to: "  Shared Name  ",
            updatedAt: renameDate
        )
        let editedProfile = edited.profiles[0]
        let renamedProfile = renamed.profiles[0]

        #expect(collection.profiles[0] == original)
        #expect(editedProfile.id == originalID)
        #expect(editedProfile.createdAt == createdAt)
        #expect(editedProfile.lastOpenedAt == lastOpenedAt)
        #expect(editedProfile.sortOrder == 5)
        #expect(editedProfile.updatedAt == editDate)
        #expect(!editedProfile.favorite)
        #expect(editedProfile.configuration == .ssh(.configAlias(alias: "research-cluster")))
        #expect(renamedProfile.id == originalID)
        #expect(renamedProfile.createdAt == createdAt)
        #expect(renamedProfile.name == "Shared Name")
        #expect(renamedProfile.updatedAt == renameDate)
        #expect(renamed.profiles.map(\.name) == ["Shared Name", "Shared Name"])
    }

    @Test("Duplicate copies launch configuration but resets identity, favorite, recency, and ordering")
    func duplicateAppliesResetRules() throws {
        let originalID = profileID("50000000-0000-0000-0000-000000000001")
        let copyID = profileID("50000000-0000-0000-0000-000000000002")
        let original = makeProfile(
            id: originalID,
            name: "Relay Host",
            favorite: true,
            createdAt: Date(timeIntervalSinceReferenceDate: 10),
            updatedAt: Date(timeIntervalSinceReferenceDate: 20),
            lastOpenedAt: Date(timeIntervalSinceReferenceDate: 30),
            sortOrder: 9,
            configuration: .ssh(
                .direct(
                    host: "relay.example.test",
                    port: 2_222,
                    user: "alice",
                    identityFilePath: "/Users/alice/.ssh/id_test"
                )
            )
        )
        let collection = try SessionProfileCollection(profiles: [original])
        let copyCreatedAt = Date(timeIntervalSinceReferenceDate: 100)
        let copyUpdatedAt = Date(timeIntervalSinceReferenceDate: 101)

        let duplicated = try collection.duplicating(
            id: originalID,
            newID: copyID,
            createdAt: copyCreatedAt,
            updatedAt: copyUpdatedAt
        )
        let copy = duplicated.profiles[1]

        #expect(collection.profiles == [original])
        #expect(copy.id == copyID)
        #expect(copy.name == "Relay Host Copy")
        #expect(copy.configuration == original.configuration)
        #expect(!copy.favorite)
        #expect(copy.lastOpenedAt == nil)
        #expect(copy.createdAt == copyCreatedAt)
        #expect(copy.updatedAt == copyUpdatedAt)
        #expect(copy.sortOrder == 10)
    }

    @Test("Delete removes the complete saved, favorite, and recent profile state")
    func deleteRemovesAllProjectedStateWithoutMutatingTheOldCollection() throws {
        let id = profileID("60000000-0000-0000-0000-000000000001")
        let profile = makeProfile(
            id: id,
            name: "Disposable",
            favorite: true,
            lastOpenedAt: Date(timeIntervalSinceReferenceDate: 100),
            sortOrder: 0
        )
        let collection = try SessionProfileCollection(profiles: [profile])

        let deleted = try collection.deleting(id: id)

        #expect(deleted.profiles.isEmpty)
        #expect(deleted.favoriteProfileIDs.isEmpty)
        #expect(deleted.recentProfileIDs().isEmpty)
        #expect(collection.profiles == [profile])
        #expect(collection.favoriteProfileIDs == [id])
        #expect(collection.recentProfileIDs() == [id])
    }

    @Test("Favorite changes are timestamped and idempotent")
    func favoriteAndUnfavoriteArePersistentAndIdempotent() throws {
        let id = profileID("70000000-0000-0000-0000-000000000001")
        let profile = makeProfile(
            id: id,
            name: "Favorite Me",
            updatedAt: Date(timeIntervalSinceReferenceDate: 10),
            sortOrder: 0
        )
        let collection = try SessionProfileCollection(profiles: [profile])
        let favoriteDate = Date(timeIntervalSinceReferenceDate: 20)
        let favorited = try collection.settingFavorite(true, for: id, updatedAt: favoriteDate)
        let repeated = try favorited.settingFavorite(
            true,
            for: id,
            updatedAt: Date(timeIntervalSinceReferenceDate: 30)
        )
        let unfavoriteDate = Date(timeIntervalSinceReferenceDate: 40)
        let unfavorited = try repeated.settingFavorite(false, for: id, updatedAt: unfavoriteDate)

        #expect(!collection.profiles[0].favorite)
        #expect(favorited.profiles[0].favorite)
        #expect(favorited.profiles[0].updatedAt == favoriteDate)
        #expect(repeated == favorited)
        #expect(!unfavorited.profiles[0].favorite)
        #expect(unfavorited.profiles[0].updatedAt == unfavoriteDate)
    }

    @Test("Confirmed opens produce recent IDs that are unique, newest first, and capped")
    func recentProjectionIsOrderedDeduplicatedAndCapped() throws {
        let profiles = (0..<10).map { index in
            makeProfile(
                id: indexedProfileID(index),
                name: "Profile \(index)",
                sortOrder: index
            )
        }
        let original = try SessionProfileCollection(profiles: profiles)
        let opened = try profiles.enumerated().reduce(original) { collection, entry in
            try collection.recordingOpened(
                id: entry.element.id,
                at: Date(timeIntervalSinceReferenceDate: Double(entry.offset + 1))
            )
        }
        let reopenedDate = Date(timeIntervalSinceReferenceDate: 100)
        let reopened = try opened.recordingOpened(
            id: profiles[4].id,
            at: reopenedDate
        )

        #expect(original.recentProfileIDs().isEmpty)
        #expect(reopened.recentProfileIDs().count == 8)
        #expect(reopened.recentProfileIDs().first == profiles[4].id)
        #expect(
            reopened.recentProfileIDs(limit: 3) == [
                profiles[4].id,
                profiles[9].id,
                profiles[8].id
            ]
        )
        #expect(Set(reopened.recentProfileIDs()).count == reopened.recentProfileIDs().count)
        #expect(reopened.recentProfileIDs(limit: 0).isEmpty)
        #expect(reopened.profiles[4].lastOpenedAt == reopenedDate)
        #expect(reopened.profiles[4].updatedAt == reopenedDate)
        #expect(opened.profiles[4].lastOpenedAt == Date(timeIntervalSinceReferenceDate: 5))
    }

    @Test("Mutations report typed not-found errors")
    func missingProfilesAreReportedByEveryTargetedMutation() throws {
        let missingID = profileID("90000000-0000-0000-0000-000000000001")
        let freshID = profileID("90000000-0000-0000-0000-000000000002")
        let collection = SessionProfileCollection()
        let date = Date(timeIntervalSinceReferenceDate: 10)

        #expect(throws: SessionProfileCollectionError.profileNotFound(missingID)) {
            try collection.editing(
                id: missingID,
                with: localDraft(),
                updatedAt: date
            )
        }
        #expect(throws: SessionProfileCollectionError.profileNotFound(missingID)) {
            try collection.renaming(id: missingID, to: "Missing", updatedAt: date)
        }
        #expect(throws: SessionProfileCollectionError.profileNotFound(missingID)) {
            try collection.duplicating(
                id: missingID,
                newID: freshID,
                createdAt: date,
                updatedAt: date
            )
        }
        #expect(throws: SessionProfileCollectionError.profileNotFound(missingID)) {
            try collection.deleting(id: missingID)
        }
        #expect(throws: SessionProfileCollectionError.profileNotFound(missingID)) {
            try collection.settingFavorite(true, for: missingID, updatedAt: date)
        }
        #expect(throws: SessionProfileCollectionError.profileNotFound(missingID)) {
            try collection.recordingOpened(
                id: missingID,
                at: date
            )
        }
    }

    private func makeProfile(
        id: SessionProfileID,
        name: String,
        favorite: Bool = false,
        createdAt: Date = Date(timeIntervalSinceReferenceDate: 1),
        updatedAt: Date = Date(timeIntervalSinceReferenceDate: 2),
        lastOpenedAt: Date? = nil,
        sortOrder: Int,
        configuration: SessionProfileConfiguration = .local(
            LocalSessionProfile(useLoginShell: true, shellPath: nil, workingDirectory: nil)
        )
    ) -> SessionProfile {
        SessionProfile(
            id: id,
            name: name,
            favorite: favorite,
            createdAt: createdAt,
            updatedAt: updatedAt,
            lastOpenedAt: lastOpenedAt,
            sortOrder: sortOrder,
            configuration: configuration
        )
    }

    private func localDraft(name: String = "Local Terminal") -> SessionProfileDraft {
        SessionProfileDraft(
            name: name,
            favorite: false,
            kind: .local,
            local: LocalSessionProfileDraft(
                mode: .loginShell,
                shellPath: "",
                workingDirectory: ""
            ),
            ssh: SSHSessionProfileDraft(
                mode: .direct,
                host: "",
                port: "",
                user: "",
                sshConfigAlias: "",
                identityFilePath: ""
            )
        )
    }

    private func sshDraft(
        name: String = "SSH Session",
        favorite: Bool = false,
        mode: SSHSessionProfileDraftMode = .direct
    ) -> SessionProfileDraft {
        SessionProfileDraft(
            name: name,
            favorite: favorite,
            kind: .ssh,
            local: LocalSessionProfileDraft(
                mode: .loginShell,
                shellPath: "",
                workingDirectory: ""
            ),
            ssh: SSHSessionProfileDraft(
                mode: mode,
                host: "host.example.test",
                port: "22",
                user: "user",
                sshConfigAlias: "research-cluster",
                identityFilePath: ""
            )
        )
    }

    private func profileID(_ value: String) -> SessionProfileID {
        SessionProfileID(rawValue: UUID(uuidString: value)!)
    }

    private func indexedProfileID(_ index: Int) -> SessionProfileID {
        profileID(String(format: "80000000-0000-0000-0000-%012d", index + 1))
    }

    private func collectionValidationError(
        _ operation: () throws -> SessionProfileCollection
    ) -> SessionProfileValidationError? {
        do {
            _ = try operation()
            Issue.record("Expected collection validation to fail")
            return nil
        } catch let error as SessionProfileValidationError {
            return error
        } catch {
            Issue.record("Expected SessionProfileValidationError, received \(error)")
            return nil
        }
    }

    private func requireSendable<T: Sendable>(_ value: T) {
        _ = value
    }
}

private extension SessionProfileConfiguration {
    var isLocal: Bool {
        if case .local = self { return true }
        return false
    }

    var isSSH: Bool {
        if case .ssh = self { return true }
        return false
    }
}
