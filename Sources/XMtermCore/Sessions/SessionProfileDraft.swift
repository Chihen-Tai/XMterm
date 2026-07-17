public struct SessionProfileDraft: Hashable, Sendable {
    public var name: String
    public var favorite: Bool
    public var kind: SessionProfileDraftKind
    public var local: LocalSessionProfileDraft
    public var ssh: SSHSessionProfileDraft

    public init(
        name: String,
        favorite: Bool,
        kind: SessionProfileDraftKind,
        local: LocalSessionProfileDraft,
        ssh: SSHSessionProfileDraft
    ) {
        self.name = name
        self.favorite = favorite
        self.kind = kind
        self.local = local
        self.ssh = ssh
    }
}

public enum SessionProfileDraftKind: Hashable, Sendable {
    case local
    case ssh
}

public struct LocalSessionProfileDraft: Hashable, Sendable {
    public var mode: LocalSessionProfileDraftMode
    public var shellPath: String
    public var workingDirectory: String

    public init(
        mode: LocalSessionProfileDraftMode,
        shellPath: String,
        workingDirectory: String
    ) {
        self.mode = mode
        self.shellPath = shellPath
        self.workingDirectory = workingDirectory
    }
}

public enum LocalSessionProfileDraftMode: Hashable, Sendable {
    case loginShell
    case customShell
}

public struct SSHSessionProfileDraft: Hashable, Sendable {
    public var mode: SSHSessionProfileDraftMode
    public var host: String
    public var port: String
    public var user: String
    public var sshConfigAlias: String
    public var identityFilePath: String

    public init(
        mode: SSHSessionProfileDraftMode,
        host: String,
        port: String,
        user: String,
        sshConfigAlias: String,
        identityFilePath: String
    ) {
        self.mode = mode
        self.host = host
        self.port = port
        self.user = user
        self.sshConfigAlias = sshConfigAlias
        self.identityFilePath = identityFilePath
    }
}

public enum SSHSessionProfileDraftMode: Hashable, Sendable {
    case direct
    case configAlias
}
