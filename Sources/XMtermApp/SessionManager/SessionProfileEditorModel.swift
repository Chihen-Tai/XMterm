import Foundation
import XMtermCore

enum SessionProfileEditorDrafts {
    static func newProfile(kind: SessionProfileDraftKind) -> SessionProfileDraft {
        SessionProfileDraft(
            name: kind == .local ? "New Local Session" : "New SSH Session",
            favorite: false,
            kind: kind,
            local: LocalSessionProfileDraft(
                mode: .loginShell,
                shellPath: "",
                workingDirectory: ""
            ),
            ssh: SSHSessionProfileDraft(
                mode: .direct,
                host: "",
                port: "22",
                user: "",
                sshConfigAlias: "",
                identityFilePath: ""
            )
        )
    }

    static func editing(_ profile: SessionProfile) -> SessionProfileDraft {
        SessionProfileValidator.editingDraft(from: profile)
    }

    /// Pure structural validation for responsive editor feedback. This intentionally
    /// performs no filesystem or executable lookup.
    static func structuralIssues(
        for draft: SessionProfileDraft
    ) -> [SessionProfileValidationIssue] {
        do {
            _ = try SessionProfileValidator.validatedProfile(
                from: draft,
                id: SessionProfileID(
                    rawValue: UUID(
                        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)
                    )
                ),
                createdAt: .distantPast,
                updatedAt: .distantPast,
                lastOpenedAt: nil,
                sortOrder: 0
            )
            return []
        } catch let error as SessionProfileValidationError {
            return error.issues
        } catch {
            return [
                SessionProfileValidationIssue(
                    field: .name,
                    reason: .required
                )
            ]
        }
    }

    static func message(for issue: SessionProfileValidationIssue) -> String {
        switch issue.reason {
        case .required:
            "This field is required."
        case .containsControlCharacter:
            "Control characters are not allowed."
        case .containsWhitespace:
            "Whitespace is not allowed."
        case .containsAtSign:
            "Do not include an @ sign here."
        case .startsWithHyphen:
            "The value cannot start with a hyphen."
        case .invalidInteger:
            "Enter a whole-number port."
        case .outOfRange:
            "Enter a port from 1 through 65535."
        case .mustBeAbsolutePath:
            "Enter an absolute path beginning with /."
        case .contradictsSelectedMode:
            "This value is unavailable in the selected mode."
        case .mustBeCanonical:
            "Remove leading or trailing whitespace."
        }
    }

    static func message(for issue: SessionProfilePathIssue) -> String {
        switch issue.reason {
        case .missing:
            "The selected path does not exist."
        case .notDirectory:
            "The selected path is not a directory."
        case .notReadableFile:
            "The selected file is not readable."
        case .notExecutable:
            "The selected file is not executable."
        }
    }
}
