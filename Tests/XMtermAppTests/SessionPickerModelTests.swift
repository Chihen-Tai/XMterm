import Foundation
import Testing
import XMtermCore
@testable import XMtermApp

@Suite("Session picker projection")
struct SessionPickerModelTests {
    @Test("[SESS-009] grouped sections are unique with documented precedence")
    func sectionPrecedenceRemovesDuplicates() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let recentFavoriteSSH = makeProfile(
            ordinal: 1,
            name: "Recent Favorite SSH",
            favorite: true,
            lastOpenedAt: now,
            configuration: .ssh(.configAlias(alias: "recent"))
        )
        let favoriteLocal = makeProfile(
            ordinal: 2,
            name: "Favorite Local",
            favorite: true,
            configuration: .local(.init(useLoginShell: true, shellPath: nil, workingDirectory: nil))
        )
        let ssh = makeProfile(
            ordinal: 3,
            name: "SSH",
            configuration: .ssh(.configAlias(alias: "ssh"))
        )
        let local = makeProfile(
            ordinal: 4,
            name: "Local",
            configuration: .local(.init(useLoginShell: true, shellPath: nil, workingDirectory: nil))
        )
        let collection = try SessionProfileCollection(
            profiles: [recentFavoriteSSH, favoriteLocal, ssh, local]
        )

        let model = SessionPickerModel(collection: collection)

        #expect(model.sections.map(\.kind) == [.recent, .favorites, .ssh, .local])
        #expect(model.sections.map(\.profileIDs) == [
            [recentFavoriteSSH.id],
            [favoriteLocal.id],
            [ssh.id],
            [local.id]
        ])
        #expect(Set(model.orderedProfileIDs).count == 4)
    }

    @Test("[SESS-009] recents are newest first and capped at eight")
    func recentsAreOrderedAndCapped() throws {
        let profiles = (0..<10).map { index in
            makeProfile(
                ordinal: index,
                name: "Recent \(index)",
                lastOpenedAt: Date(timeIntervalSince1970: TimeInterval(index + 1)),
                configuration: .ssh(.configAlias(alias: "host-\(index)"))
            )
        }
        let model = SessionPickerModel(
            collection: try SessionProfileCollection(profiles: profiles)
        )

        #expect(model.sections.first?.kind == .recent)
        #expect(model.sections.first?.profileIDs == profiles.reversed().prefix(8).map(\.id))
        #expect(model.sections.last?.kind == .ssh)
        #expect(model.sections.last?.profileIDs == profiles.prefix(2).map(\.id))
    }

    @Test("[SESS-009] search covers name, direct host, user, alias, and custom shell")
    func searchCoversEveryDocumentedField() throws {
        let profiles = [
            makeProfile(
                ordinal: 1,
                name: "Café Terminal",
                configuration: .local(.init(useLoginShell: true, shellPath: nil, workingDirectory: nil))
            ),
            makeProfile(
                ordinal: 2,
                name: "Direct",
                configuration: .ssh(
                    .direct(
                        host: "compute.example",
                        port: 22,
                        user: "Researcher",
                        identityFilePath: nil
                    )
                )
            ),
            makeProfile(
                ordinal: 3,
                name: "Alias",
                configuration: .ssh(.configAlias(alias: "gpu-cluster"))
            ),
            makeProfile(
                ordinal: 4,
                name: "Shell",
                configuration: .local(
                    .init(
                        useLoginShell: false,
                        shellPath: "/opt/homebrew/bin/fish",
                        workingDirectory: nil
                    )
                )
            )
        ]
        let collection = try SessionProfileCollection(profiles: profiles)

        #expect(search(collection, " cafe ") == [profiles[0].id])
        #expect(search(collection, "COMPUTE.EXAMPLE") == [profiles[1].id])
        #expect(search(collection, "researcher") == [profiles[1].id])
        #expect(search(collection, "GPU-CLUSTER") == [profiles[2].id])
        #expect(search(collection, "homebrew/bin/fish") == [profiles[3].id])
    }

    @Test("[SESS-009] blank search restores grouping and unmatched search is explicit empty state")
    func blankAndUnmatchedQueriesAreDistinct() throws {
        let profile = makeProfile(
            ordinal: 1,
            name: "Local",
            configuration: .local(.init(useLoginShell: true, shellPath: nil, workingDirectory: nil))
        )
        let collection = try SessionProfileCollection(profiles: [profile])

        let blank = SessionPickerModel(collection: collection, query: "  \n")
        let unmatched = SessionPickerModel(collection: collection, query: "missing")

        #expect(blank.sections.map(\.kind) == [.local])
        #expect(!blank.isSearching)
        #expect(unmatched.sections.isEmpty)
        #expect(unmatched.orderedProfileIDs.isEmpty)
        #expect(unmatched.isSearching)
        #expect(unmatched.selectedProfileID == nil)
        #expect(unmatched.launchProfileID == nil)
    }

    @Test("[SESS-009] search results retain stable profile IDs in one results section")
    func searchResultsRetainStableIDs() throws {
        let first = makeProfile(
            ordinal: 1,
            name: "Local Alpha",
            configuration: .local(.init(useLoginShell: true, shellPath: nil, workingDirectory: nil))
        )
        let second = makeProfile(
            ordinal: 2,
            name: "Local Beta",
            configuration: .local(.init(useLoginShell: true, shellPath: nil, workingDirectory: nil))
        )
        let collection = try SessionProfileCollection(profiles: [first, second])

        let model = SessionPickerModel(collection: collection, query: "local")

        #expect(model.sections.map(\.kind) == [.searchResults])
        #expect(model.sections.first?.profileIDs == [first.id, second.id])
        #expect(model.profile(id: first.id) == first)
        #expect(model.profile(id: SessionProfileID()) == nil)
    }

    @Test("[SESS-009] initial and stale keyboard selections normalize to the first row")
    func initialAndStaleSelectionsNormalize() throws {
        let first = makeProfile(ordinal: 1, name: "First")
        let second = makeProfile(ordinal: 2, name: "Second")
        let collection = try SessionProfileCollection(profiles: [first, second])

        let initial = SessionPickerModel(collection: collection)
        let stale = SessionPickerModel(
            collection: collection,
            selectedProfileID: SessionProfileID()
        )

        #expect(initial.selectedProfileID == first.id)
        #expect(stale.selectedProfileID == first.id)
        #expect(initial.launchProfileID == first.id)
    }

    @Test("[SESS-009] arrow movement follows visible order and clamps at both ends")
    func keyboardMovementClamps() throws {
        let profiles = (1...3).map { makeProfile(ordinal: $0, name: "Profile \($0)") }
        let collection = try SessionProfileCollection(profiles: profiles)
        let initial = SessionPickerModel(collection: collection)

        let second = initial.movingSelection(.next)
        let third = second.movingSelection(.next)

        #expect(second.selectedProfileID == profiles[1].id)
        #expect(third.selectedProfileID == profiles[2].id)
        #expect(third.movingSelection(.next).selectedProfileID == profiles[2].id)
        #expect(initial.movingSelection(.previous).selectedProfileID == profiles[0].id)
        #expect(third.movingSelection(.previous).selectedProfileID == profiles[1].id)
    }

    @Test("[SESS-009] changing a query repairs selection without using array indices")
    func queryChangeRepairsSelectionByStableID() throws {
        let alpha = makeProfile(ordinal: 1, name: "Alpha")
        let beta = makeProfile(ordinal: 2, name: "Beta")
        let collection = try SessionProfileCollection(profiles: [alpha, beta])
        let selected = SessionPickerModel(
            collection: collection,
            selectedProfileID: beta.id
        )

        let filtered = selected.updatingQuery("alpha")
        let restored = filtered.updatingQuery("")

        #expect(filtered.selectedProfileID == alpha.id)
        #expect(filtered.launchProfileID == alpha.id)
        #expect(restored.orderedProfileIDs == [alpha.id, beta.id])
        #expect(restored.selectedProfileID == alpha.id)
    }

    @Test("[SESS-009] a 100-profile projection stays complete, ordered, and unique")
    func hundredProfileProjection() throws {
        let profiles = (0..<100).map { index in
            makeProfile(
                ordinal: index,
                name: "Profile \(index)",
                favorite: index.isMultiple(of: 10),
                lastOpenedAt: index < 8
                    ? Date(timeIntervalSince1970: TimeInterval(index + 1))
                    : nil,
                configuration: index.isMultiple(of: 2)
                    ? .local(.init(useLoginShell: true, shellPath: nil, workingDirectory: nil))
                    : .ssh(.configAlias(alias: "alias-\(index)"))
            )
        }
        let model = SessionPickerModel(
            collection: try SessionProfileCollection(profiles: profiles)
        )

        #expect(model.orderedProfileIDs.count == 100)
        #expect(Set(model.orderedProfileIDs).count == 100)
        #expect(model.sections.first?.kind == .recent)
        #expect(model.sections.first?.profileIDs.count == 8)
    }

    @Test("[SESS-007, SESS-009] Command-T chooses the first saved login-shell profile")
    func defaultLaunchChoosesFirstLoginShellByStableOrder() throws {
        let custom = makeProfile(
            ordinal: 1,
            name: "Custom",
            configuration: .local(
                .init(
                    useLoginShell: false,
                    shellPath: "/bin/zsh",
                    workingDirectory: nil
                )
            )
        )
        let laterLogin = makeProfile(ordinal: 4, name: "Later Login")
        let firstLogin = makeProfile(ordinal: 2, name: "First Login")
        let ssh = makeProfile(
            ordinal: 0,
            name: "SSH",
            configuration: .ssh(.configAlias(alias: "cluster"))
        )
        let collection = try SessionProfileCollection(
            profiles: [laterLogin, custom, ssh, firstLogin]
        )

        #expect(
            SessionProfileLaunchPolicy.defaultLocalProfileID(in: collection)
                == firstLogin.id
        )
    }

    @Test("[SESS-009] Command-T has no fallback when no login-shell profile is saved")
    func defaultLaunchRequiresSavedLoginShell() throws {
        let collection = try SessionProfileCollection(
            profiles: [
                makeProfile(
                    ordinal: 1,
                    name: "Custom",
                    configuration: .local(
                        .init(
                            useLoginShell: false,
                            shellPath: "/bin/zsh",
                            workingDirectory: nil
                        )
                    )
                ),
                makeProfile(
                    ordinal: 2,
                    name: "SSH",
                    configuration: .ssh(.configAlias(alias: "cluster"))
                )
            ]
        )

        #expect(SessionProfileLaunchPolicy.defaultLocalProfileID(in: collection) == nil)
    }

    private func search(
        _ collection: SessionProfileCollection,
        _ query: String
    ) -> [SessionProfileID] {
        SessionPickerModel(collection: collection, query: query).orderedProfileIDs
    }

    private func makeProfile(
        ordinal: Int,
        name: String,
        favorite: Bool = false,
        lastOpenedAt: Date? = nil,
        configuration: SessionProfileConfiguration = .local(
            .init(useLoginShell: true, shellPath: nil, workingDirectory: nil)
        )
    ) -> SessionProfile {
        let value = UInt32(ordinal + 1)
        let uuid = UUID(
            uuid: (
                0, 0, 0, 0,
                0, 0,
                0, 0,
                0, 0,
                UInt8((value >> 24) & 0xff),
                UInt8((value >> 16) & 0xff),
                UInt8((value >> 8) & 0xff),
                UInt8(value & 0xff),
                0, 1
            )
        )
        let date = Date(timeIntervalSince1970: 1)
        return SessionProfile(
            id: SessionProfileID(rawValue: uuid),
            name: name,
            favorite: favorite,
            createdAt: date,
            updatedAt: date,
            lastOpenedAt: lastOpenedAt,
            sortOrder: ordinal,
            configuration: configuration
        )
    }
}
