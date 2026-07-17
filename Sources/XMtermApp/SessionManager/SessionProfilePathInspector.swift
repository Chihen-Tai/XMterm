import Foundation
import XMtermCore

protocol SessionProfilePathInspecting: Sendable {
    func inspect(_ profile: SessionProfile) async -> [SessionProfilePathIssue]
}

struct SessionProfilePathIssue: Equatable, Hashable, Sendable {
    let field: SessionProfileValidationField
    let reason: SessionProfilePathIssueReason

    init(
        field: SessionProfileValidationField,
        reason: SessionProfilePathIssueReason
    ) {
        self.field = field
        self.reason = reason
    }
}

enum SessionProfilePathIssueReason: Equatable, Hashable, Sendable {
    case missing
    case notExecutable
    case notDirectory
    case notReadableFile
}

actor FoundationSessionProfilePathInspector: SessionProfilePathInspecting {
    func inspect(_ profile: SessionProfile) async -> [SessionProfilePathIssue] {
        switch profile.configuration {
        case .local(let local):
            inspect(local)

        case .ssh(let ssh):
            inspect(ssh)
        }
    }

    private func inspect(_ profile: LocalSessionProfile) -> [SessionProfilePathIssue] {
        let shellIssues: [SessionProfilePathIssue]
        if profile.useLoginShell {
            shellIssues = []
        } else if let shellPath = profile.shellPath {
            shellIssues = inspectExecutable(at: shellPath, field: .shellPath)
        } else {
            shellIssues = [.init(field: .shellPath, reason: .missing)]
        }

        let workingDirectoryIssues = profile.workingDirectory.map {
            inspectDirectory(at: $0, field: .workingDirectory)
        } ?? []

        return shellIssues + workingDirectoryIssues
    }

    private func inspect(_ profile: SSHSessionProfile) -> [SessionProfilePathIssue] {
        switch profile {
        case .configAlias:
            []

        case .direct(_, _, _, let identityFilePath):
            identityFilePath.map {
                inspectReadableFile(at: $0, field: .identityFilePath)
            } ?? []
        }
    }

    private func inspectExecutable(
        at path: String,
        field: SessionProfileValidationField
    ) -> [SessionProfilePathIssue] {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return [.init(field: field, reason: .missing)]
        }
        guard !isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: path) else {
            return [.init(field: field, reason: .notExecutable)]
        }
        return []
    }

    private func inspectDirectory(
        at path: String,
        field: SessionProfileValidationField
    ) -> [SessionProfilePathIssue] {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return [.init(field: field, reason: .missing)]
        }
        guard isDirectory.boolValue else {
            return [.init(field: field, reason: .notDirectory)]
        }
        return []
    }

    private func inspectReadableFile(
        at path: String,
        field: SessionProfileValidationField
    ) -> [SessionProfilePathIssue] {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return [.init(field: field, reason: .missing)]
        }
        guard !isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: path) else {
            return [.init(field: field, reason: .notReadableFile)]
        }
        return []
    }
}
