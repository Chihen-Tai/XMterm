import Foundation

public enum SessionProfileValidationField: String, Hashable, Sendable {
    case name
    case host
    case port
    case user
    case sshConfigAlias
    case identityFilePath
    case shellPath
    case workingDirectory
}

public enum SessionProfileValidationReason: Hashable, Sendable {
    case required
    case containsControlCharacter
    case containsWhitespace
    case containsAtSign
    case startsWithHyphen
    case invalidInteger
    case outOfRange
    case mustBeAbsolutePath
    case contradictsSelectedMode
    case mustBeCanonical
}

public struct SessionProfileValidationIssue: Hashable, Sendable {
    public let field: SessionProfileValidationField
    public let reason: SessionProfileValidationReason

    public init(
        field: SessionProfileValidationField,
        reason: SessionProfileValidationReason
    ) {
        self.field = field
        self.reason = reason
    }
}

public struct SessionProfileValidationError: Error, Equatable, Sendable {
    public let issues: [SessionProfileValidationIssue]

    public var fields: Set<SessionProfileValidationField> {
        Set(issues.map(\.field))
    }

    public init(issues: [SessionProfileValidationIssue]) {
        self.issues = issues
    }
}

public enum SessionProfileValidator {
    public static func validatedProfile(
        from draft: SessionProfileDraft,
        id: SessionProfileID,
        createdAt: Date,
        updatedAt: Date,
        lastOpenedAt: Date?,
        sortOrder: Int
    ) throws -> SessionProfile {
        let name = validateName(draft.name)
        let configuration = validateConfiguration(draft)
        let issues = name.issues + configuration.issues

        guard issues.isEmpty else {
            throw SessionProfileValidationError(issues: issues)
        }

        return SessionProfile(
            id: id,
            name: name.value,
            favorite: draft.favorite,
            createdAt: createdAt,
            updatedAt: updatedAt,
            lastOpenedAt: lastOpenedAt,
            sortOrder: sortOrder,
            configuration: configuration.value
        )
    }

    public static func validatedProfile(_ profile: SessionProfile) throws -> SessionProfile {
        if case .local(let local) = profile.configuration,
           local.useLoginShell,
           local.shellPath != nil {
            throw SessionProfileValidationError(
                issues: [
                    .init(field: .shellPath, reason: .contradictsSelectedMode)
                ]
            )
        }

        let canonicalProfile = try validatedProfile(
            from: draft(from: profile),
            id: profile.id,
            createdAt: profile.createdAt,
            updatedAt: profile.updatedAt,
            lastOpenedAt: profile.lastOpenedAt,
            sortOrder: profile.sortOrder
        )
        let canonicalityIssues = canonicalityIssues(
            original: profile,
            canonical: canonicalProfile
        )
        guard canonicalityIssues.isEmpty else {
            throw SessionProfileValidationError(issues: canonicalityIssues)
        }
        return profile
    }

    package static func editingDraft(from profile: SessionProfile) -> SessionProfileDraft {
        draft(from: profile)
    }

    private static func validateConfiguration(
        _ draft: SessionProfileDraft
    ) -> ValidationResult<SessionProfileConfiguration> {
        switch draft.kind {
        case .local:
            validateLocal(draft.local)
        case .ssh:
            validateSSH(draft.ssh)
        }
    }

    private static func validateLocal(
        _ draft: LocalSessionProfileDraft
    ) -> ValidationResult<SessionProfileConfiguration> {
        let workingDirectory = validateOptionalAbsolutePath(
            draft.workingDirectory,
            field: .workingDirectory
        )

        switch draft.mode {
        case .loginShell:
            return ValidationResult(
                value: .local(
                    LocalSessionProfile(
                        useLoginShell: true,
                        shellPath: nil,
                        workingDirectory: workingDirectory.value
                    )
                ),
                issues: workingDirectory.issues
            )

        case .customShell:
            let shellPath = validateRequiredAbsolutePath(draft.shellPath, field: .shellPath)
            return ValidationResult(
                value: .local(
                    LocalSessionProfile(
                        useLoginShell: false,
                        shellPath: shellPath.value,
                        workingDirectory: workingDirectory.value
                    )
                ),
                issues: shellPath.issues + workingDirectory.issues
            )
        }
    }

    private static func validateSSH(
        _ draft: SSHSessionProfileDraft
    ) -> ValidationResult<SessionProfileConfiguration> {
        switch draft.mode {
        case .direct:
            validateDirectSSH(draft)
        case .configAlias:
            validateConfigAlias(draft.sshConfigAlias)
        }
    }

    private static func validateDirectSSH(
        _ draft: SSHSessionProfileDraft
    ) -> ValidationResult<SessionProfileConfiguration> {
        let host = validateSSHIdentifier(draft.host, field: .host, rejectLeadingHyphen: false)
        let port = validatePort(draft.port)
        let user = validateSSHIdentifier(draft.user, field: .user, rejectLeadingHyphen: true)
        let identityFilePath = validateOptionalAbsolutePath(
            draft.identityFilePath,
            field: .identityFilePath
        )

        return ValidationResult(
            value: .ssh(
                .direct(
                    host: host.value,
                    port: port.value ?? 0,
                    user: user.value,
                    identityFilePath: identityFilePath.value
                )
            ),
            issues: host.issues + port.issues + user.issues + identityFilePath.issues
        )
    }

    private static func validateConfigAlias(
        _ rawValue: String
    ) -> ValidationResult<SessionProfileConfiguration> {
        let alias = validateSSHIdentifier(
            rawValue,
            field: .sshConfigAlias,
            rejectLeadingHyphen: true,
            rejectAtSign: false
        )
        return ValidationResult(
            value: .ssh(.configAlias(alias: alias.value)),
            issues: alias.issues
        )
    }

    private static func validateName(_ rawValue: String) -> ValidationResult<String> {
        let value = normalized(rawValue)
        let issues = issueIf(value.isEmpty, field: .name, reason: .required)
            + issueIf(
                containsC0OrC1Control(rawValue),
                field: .name,
                reason: .containsControlCharacter
            )
        return ValidationResult(value: value, issues: issues)
    }

    private static func validateSSHIdentifier(
        _ rawValue: String,
        field: SessionProfileValidationField,
        rejectLeadingHyphen: Bool,
        rejectAtSign: Bool = true
    ) -> ValidationResult<String> {
        let value = normalized(rawValue)
        let issues = issueIf(value.isEmpty, field: field, reason: .required)
            + issueIf(
                containsC0OrC1Control(rawValue),
                field: field,
                reason: .containsControlCharacter
            )
            + issueIf(
                value.contains(where: \.isWhitespace),
                field: field,
                reason: .containsWhitespace
            )
            + issueIf(
                rejectAtSign && value.contains("@"),
                field: field,
                reason: .containsAtSign
            )
            + issueIf(
                rejectLeadingHyphen && value.hasPrefix("-"),
                field: field,
                reason: .startsWithHyphen
            )
        return ValidationResult(value: value, issues: issues)
    }

    private static func validatePort(_ rawValue: String) -> ValidationResult<Int?> {
        let controlIssues = issueIf(
            containsC0OrC1Control(rawValue),
            field: .port,
            reason: .containsControlCharacter
        )
        let value = Int(normalized(rawValue))
        guard let value else {
            return ValidationResult(
                value: nil,
                issues: controlIssues + [.init(field: .port, reason: .invalidInteger)]
            )
        }
        guard (1...65_535).contains(value) else {
            return ValidationResult(
                value: value,
                issues: controlIssues + [.init(field: .port, reason: .outOfRange)]
            )
        }
        return ValidationResult(value: value, issues: controlIssues)
    }

    private static func validateRequiredAbsolutePath(
        _ rawValue: String,
        field: SessionProfileValidationField
    ) -> ValidationResult<String> {
        let value = normalized(rawValue)
        let issues = issueIf(value.isEmpty, field: field, reason: .required)
            + issueIf(
                containsC0OrC1Control(rawValue),
                field: field,
                reason: .containsControlCharacter
            )
            + issueIf(
                !value.isEmpty && !value.hasPrefix("/"),
                field: field,
                reason: .mustBeAbsolutePath
            )
        return ValidationResult(value: value, issues: issues)
    }

    private static func validateOptionalAbsolutePath(
        _ rawValue: String,
        field: SessionProfileValidationField
    ) -> ValidationResult<String?> {
        let value = normalized(rawValue)
        let controlIssues = issueIf(
            containsC0OrC1Control(rawValue),
            field: field,
            reason: .containsControlCharacter
        )
        guard !value.isEmpty else {
            return ValidationResult(value: nil, issues: controlIssues)
        }
        let issues = controlIssues + issueIf(
            !value.hasPrefix("/"),
            field: field,
            reason: .mustBeAbsolutePath
        )
        return ValidationResult(value: value, issues: issues)
    }

    private static func canonicalityIssues(
        original: SessionProfile,
        canonical: SessionProfile
    ) -> [SessionProfileValidationIssue] {
        let nameIssues = issueIf(
            original.name != canonical.name,
            field: .name,
            reason: .mustBeCanonical
        )

        switch (original.configuration, canonical.configuration) {
        case let (.local(originalLocal), .local(canonicalLocal)):
            return nameIssues
                + issueIf(
                    originalLocal.shellPath != canonicalLocal.shellPath,
                    field: .shellPath,
                    reason: .mustBeCanonical
                )
                + issueIf(
                    originalLocal.workingDirectory != canonicalLocal.workingDirectory,
                    field: .workingDirectory,
                    reason: .mustBeCanonical
                )

        case let (.ssh(originalSSH), .ssh(canonicalSSH)):
            return nameIssues + canonicalityIssues(
                original: originalSSH,
                canonical: canonicalSSH
            )

        default:
            return nameIssues
        }
    }

    private static func canonicalityIssues(
        original: SSHSessionProfile,
        canonical: SSHSessionProfile
    ) -> [SessionProfileValidationIssue] {
        switch (original, canonical) {
        case let (
            .direct(originalHost, _, originalUser, originalIdentityFilePath),
            .direct(canonicalHost, _, canonicalUser, canonicalIdentityFilePath)
        ):
            return issueIf(
                originalHost != canonicalHost,
                field: .host,
                reason: .mustBeCanonical
            )
                + issueIf(
                    originalUser != canonicalUser,
                    field: .user,
                    reason: .mustBeCanonical
                )
                + issueIf(
                    originalIdentityFilePath != canonicalIdentityFilePath,
                    field: .identityFilePath,
                    reason: .mustBeCanonical
                )

        case let (.configAlias(originalAlias), .configAlias(canonicalAlias)):
            return issueIf(
                originalAlias != canonicalAlias,
                field: .sshConfigAlias,
                reason: .mustBeCanonical
            )

        default:
            return []
        }
    }

    private static func draft(from profile: SessionProfile) -> SessionProfileDraft {
        switch profile.configuration {
        case .local(let local):
            return SessionProfileDraft(
                name: profile.name,
                favorite: profile.favorite,
                kind: .local,
                local: LocalSessionProfileDraft(
                    mode: local.useLoginShell ? .loginShell : .customShell,
                    shellPath: local.shellPath ?? "",
                    workingDirectory: local.workingDirectory ?? ""
                ),
                ssh: emptySSHDraft
            )

        case .ssh(let ssh):
            return SessionProfileDraft(
                name: profile.name,
                favorite: profile.favorite,
                kind: .ssh,
                local: emptyLocalDraft,
                ssh: draft(from: ssh)
            )
        }
    }

    private static func draft(from profile: SSHSessionProfile) -> SSHSessionProfileDraft {
        switch profile {
        case let .direct(host, port, user, identityFilePath):
            SSHSessionProfileDraft(
                mode: .direct,
                host: host,
                port: String(port),
                user: user,
                sshConfigAlias: "",
                identityFilePath: identityFilePath ?? ""
            )
        case .configAlias(let alias):
            SSHSessionProfileDraft(
                mode: .configAlias,
                host: "",
                port: "",
                user: "",
                sshConfigAlias: alias,
                identityFilePath: ""
            )
        }
    }

    private static let emptyLocalDraft = LocalSessionProfileDraft(
        mode: .loginShell,
        shellPath: "",
        workingDirectory: ""
    )

    private static let emptySSHDraft = SSHSessionProfileDraft(
        mode: .direct,
        host: "",
        port: "",
        user: "",
        sshConfigAlias: "",
        identityFilePath: ""
    )

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func containsC0OrC1Control(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            scalar.value <= 0x1F || (0x7F...0x9F).contains(scalar.value)
        }
    }

    private static func issueIf(
        _ condition: Bool,
        field: SessionProfileValidationField,
        reason: SessionProfileValidationReason
    ) -> [SessionProfileValidationIssue] {
        condition ? [.init(field: field, reason: reason)] : []
    }
}

private struct ValidationResult<Value> {
    let value: Value
    let issues: [SessionProfileValidationIssue]
}
