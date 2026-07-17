import Foundation
import Testing
import XMtermCore
@testable import XMtermApp

@Suite("Session profile editor model")
struct SessionProfileEditorModelTests {
    @Test("[SESS-008] new drafts use safe mode-specific defaults")
    func newDraftsUseModeSpecificDefaults() {
        let local = SessionProfileEditorDrafts.newProfile(kind: .local)
        let ssh = SessionProfileEditorDrafts.newProfile(kind: .ssh)

        #expect(local.kind == .local)
        #expect(local.local.mode == .loginShell)
        #expect(local.local.shellPath.isEmpty)
        #expect(ssh.kind == .ssh)
        #expect(ssh.ssh.mode == .direct)
        #expect(ssh.ssh.port == "22")
        #expect(ssh.ssh.identityFilePath.isEmpty)
    }

    @Test("[SESS-008] per-keystroke validation is structural and accepts absent absolute paths")
    func structuralValidationDoesNotInspectFilesystem() {
        var draft = SessionProfileEditorDrafts.newProfile(kind: .local)
        draft.name = "Portable Shell"
        draft.local.mode = .customShell
        draft.local.shellPath = "/definitely/not/present/xmterm-shell"
        draft.local.workingDirectory = "/definitely/not/present/workspace"

        #expect(SessionProfileEditorDrafts.structuralIssues(for: draft).isEmpty)
    }

    @Test("[SESS-008] structural issues remain field-specific")
    func structuralIssuesRemainFieldSpecific() {
        var draft = SessionProfileEditorDrafts.newProfile(kind: .ssh)
        draft.name = " "
        draft.ssh.mode = .configAlias
        draft.ssh.sshConfigAlias = "-unsafe alias"

        let issues = SessionProfileEditorDrafts.structuralIssues(for: draft)

        #expect(Set(issues.map(\.field)) == [.name, .sshConfigAlias])
        #expect(
            SessionProfileEditorDrafts.message(
                for: .init(field: .sshConfigAlias, reason: .startsWithHyphen)
            ).localizedCaseInsensitiveContains("hyphen")
        )
    }

    @Test("[SESS-007] edit drafts preserve the tagged profile mode")
    func editDraftPreservesAliasMode() {
        let profile = SessionProfile(
            id: SessionProfileID(),
            name: "Cluster",
            favorite: true,
            createdAt: .init(timeIntervalSince1970: 1),
            updatedAt: .init(timeIntervalSince1970: 1),
            lastOpenedAt: nil,
            sortOrder: 0,
            configuration: .ssh(.configAlias(alias: "cluster"))
        )

        let draft = SessionProfileEditorDrafts.editing(profile)

        #expect(draft.name == "Cluster")
        #expect(draft.favorite)
        #expect(draft.kind == .ssh)
        #expect(draft.ssh.mode == .configAlias)
        #expect(draft.ssh.sshConfigAlias == "cluster")
    }
}
