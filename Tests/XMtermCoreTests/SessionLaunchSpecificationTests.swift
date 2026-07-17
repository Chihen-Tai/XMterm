import Foundation
import Testing
@testable import XMtermCore

@Suite("Immutable session launch specifications")
struct SessionLaunchSpecificationTests {
    @Test("[SESS-007, TAB-001] profile, tab, and terminal-session identities stay distinct")
    func profileTabAndTerminalSessionIdentitiesAreDistinct() throws {
        let profileID = SessionProfileID(
            rawValue: try #require(
                UUID(uuidString: "00000000-0000-0000-0000-000000000501")
            )
        )
        let tabID = try #require(
            UUID(uuidString: "00000000-0000-0000-0000-000000000502")
        )
        let terminalSessionID = TerminalSessionID(
            rawValue: try #require(
                UUID(uuidString: "00000000-0000-0000-0000-000000000503")
            )
        )
        let profile = makeProfile(
            id: profileID,
            name: "Research Cluster",
            configuration: .ssh(.configAlias(alias: "research-cluster"))
        )

        let specification = try SessionLaunchSpecification(profile: profile)
        let state = try TerminalTabsState().creatingTab(
            launchSpecification: specification,
            id: tabID
        )
        let tab = try #require(state.tabs.first)

        #expect(tab.id == tabID)
        #expect(tab.sourceProfileID == profileID)
        #expect(terminalSessionID.rawValue != tab.id)
        #expect(terminalSessionID.rawValue != profileID.rawValue)
        #expect(tab.id != profileID.rawValue)
    }

    @Test("[SESS-007, SESS-010] profile edits and deletion cannot alter a launched snapshot")
    func profileEditsAndDeletionDoNotAlterSnapshot() throws {
        let profileID = SessionProfileID(
            rawValue: try #require(
                UUID(uuidString: "00000000-0000-0000-0000-000000000511")
            )
        )
        let original = makeProfile(
            id: profileID,
            name: "Original Host",
            configuration: .ssh(
                .direct(
                    host: "host.example",
                    port: 22,
                    user: "researcher",
                    identityFilePath: nil
                )
            )
        )
        let specification = try SessionLaunchSpecification(profile: original)
        let collection = try SessionProfileCollection(profiles: [original])
        let edited = try collection.editing(
            id: profileID,
            with: sshAliasDraft(name: "Renamed Host", alias: "renamed-host"),
            updatedAt: Date(timeIntervalSince1970: 2)
        )
        let deleted = try edited.deleting(id: profileID)

        #expect(edited.profiles.first?.name == "Renamed Host")
        #expect(deleted.profiles.isEmpty)
        #expect(specification.initialTitle == "Original Host")
        #expect(
            specification.target == .ssh(
                .direct(
                    host: "host.example",
                    port: 22,
                    user: "researcher",
                    identityFilePath: nil
                )
            )
        )
        #expect(specification.sourceProfileID == profileID)
    }

    @Test("[SESS-007, SESS-010] tab rename preserves snapshot and profile provenance")
    func tabRenamePreservesSnapshotAndProfileProvenance() throws {
        let profileID = SessionProfileID(
            rawValue: try #require(
                UUID(uuidString: "00000000-0000-0000-0000-000000000521")
            )
        )
        let tabID = try #require(
            UUID(uuidString: "00000000-0000-0000-0000-000000000522")
        )
        let profile = makeProfile(
            id: profileID,
            name: "Login Shell",
            configuration: .local(
                LocalSessionProfile(
                    useLoginShell: true,
                    shellPath: nil,
                    workingDirectory: "/Users/example/project"
                )
            )
        )
        let specification = try SessionLaunchSpecification(profile: profile)
        let originalState = try TerminalTabsState().creatingTab(
            launchSpecification: specification,
            id: tabID
        )

        let renamedState = try originalState.updatingTitle(of: tabID, to: "Training Run")
        let renamedTab = try #require(renamedState.tabs.first)

        #expect(renamedTab.title == "Training Run")
        #expect(renamedTab.launchSpecification == specification)
        #expect(renamedTab.launchSpecification.initialTitle == "Login Shell")
        #expect(renamedTab.sourceProfileID == profileID)
        #expect(profile.name == "Login Shell")
    }

    private func makeProfile(
        id: SessionProfileID,
        name: String,
        configuration: SessionProfileConfiguration
    ) -> SessionProfile {
        SessionProfile(
            id: id,
            name: name,
            favorite: false,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1),
            lastOpenedAt: nil,
            sortOrder: 0,
            configuration: configuration
        )
    }

    private func sshAliasDraft(name: String, alias: String) -> SessionProfileDraft {
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
                mode: .configAlias,
                host: "",
                port: "",
                user: "",
                sshConfigAlias: alias,
                identityFilePath: ""
            )
        )
    }
}
