import Foundation

public struct SessionProfileID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init() {
        self.init(rawValue: UUID())
    }

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(UUID.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct SessionProfile: Identifiable, Hashable, Codable, Sendable {
    public let id: SessionProfileID
    public let name: String
    public let favorite: Bool
    public let createdAt: Date
    public let updatedAt: Date
    public let lastOpenedAt: Date?
    public let sortOrder: Int
    public let configuration: SessionProfileConfiguration

    public init(
        id: SessionProfileID,
        name: String,
        favorite: Bool,
        createdAt: Date,
        updatedAt: Date,
        lastOpenedAt: Date?,
        sortOrder: Int,
        configuration: SessionProfileConfiguration
    ) {
        self.id = id
        self.name = name
        self.favorite = favorite
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastOpenedAt = lastOpenedAt
        self.sortOrder = sortOrder
        self.configuration = configuration
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        let allowedKeys: Set<String> = [
            CodingKeys.id.rawValue,
            CodingKeys.name.rawValue,
            CodingKeys.favorite.rawValue,
            CodingKeys.createdAt.rawValue,
            CodingKeys.updatedAt.rawValue,
            CodingKeys.lastOpenedAt.rawValue,
            CodingKeys.sortOrder.rawValue,
            CodingKeys.kind.rawValue,
            kind == .local ? CodingKeys.local.rawValue : CodingKeys.ssh.rawValue
        ]
        try rejectUnknownKeys(
            from: decoder,
            allowedKeys: allowedKeys,
            context: "session profile"
        )

        id = try container.decode(SessionProfileID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        favorite = try container.decode(Bool.self, forKey: .favorite)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        lastOpenedAt = try container.decodeIfPresent(Date.self, forKey: .lastOpenedAt)
        sortOrder = try container.decode(Int.self, forKey: .sortOrder)

        switch kind {
        case .local:
            guard container.contains(.local), !container.contains(.ssh) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .kind,
                    in: container,
                    debugDescription: "A local profile must contain exactly one local payload."
                )
            }
            configuration = .local(
                try container.decode(LocalSessionProfile.self, forKey: .local)
            )

        case .ssh:
            guard container.contains(.ssh), !container.contains(.local) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .kind,
                    in: container,
                    debugDescription: "An SSH profile must contain exactly one SSH payload."
                )
            }
            configuration = .ssh(
                try container.decode(SSHSessionProfile.self, forKey: .ssh)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(favorite, forKey: .favorite)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        if let lastOpenedAt {
            try container.encode(lastOpenedAt, forKey: .lastOpenedAt)
        } else {
            try container.encodeNil(forKey: .lastOpenedAt)
        }
        try container.encode(sortOrder, forKey: .sortOrder)

        switch configuration {
        case .local(let local):
            try container.encode(Kind.local, forKey: .kind)
            try container.encode(local, forKey: .local)

        case .ssh(let ssh):
            try container.encode(Kind.ssh, forKey: .kind)
            try container.encode(ssh, forKey: .ssh)
        }
    }

    private enum Kind: String, Codable {
        case local
        case ssh
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case favorite
        case createdAt
        case updatedAt
        case lastOpenedAt
        case sortOrder
        case kind
        case local
        case ssh
    }
}

public enum SessionProfileConfiguration: Hashable, Sendable {
    case local(LocalSessionProfile)
    case ssh(SSHSessionProfile)
}

public struct LocalSessionProfile: Hashable, Codable, Sendable {
    public let useLoginShell: Bool
    public let shellPath: String?
    public let workingDirectory: String?

    public init(
        useLoginShell: Bool,
        shellPath: String?,
        workingDirectory: String?
    ) {
        self.useLoginShell = useLoginShell
        self.shellPath = shellPath
        self.workingDirectory = workingDirectory
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(
            from: decoder,
            allowedKeys: Set(CodingKeys.allCases.map(\.rawValue)),
            context: "local session payload"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        useLoginShell = try container.decode(Bool.self, forKey: .useLoginShell)
        shellPath = try container.decodeIfPresent(String.self, forKey: .shellPath)
        workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(useLoginShell, forKey: .useLoginShell)
        if let shellPath {
            try container.encode(shellPath, forKey: .shellPath)
        } else {
            try container.encodeNil(forKey: .shellPath)
        }
        if let workingDirectory {
            try container.encode(workingDirectory, forKey: .workingDirectory)
        } else {
            try container.encodeNil(forKey: .workingDirectory)
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case useLoginShell
        case shellPath
        case workingDirectory
    }
}

public enum SSHSessionProfile: Hashable, Codable, Sendable {
    case direct(host: String, port: Int, user: String, identityFilePath: String?)
    case configAlias(alias: String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let mode = try container.decode(Mode.self, forKey: .mode)
        let allowedKeys: Set<String>

        switch mode {
        case .direct:
            allowedKeys = [
                CodingKeys.mode.rawValue,
                CodingKeys.host.rawValue,
                CodingKeys.port.rawValue,
                CodingKeys.user.rawValue,
                CodingKeys.identityFilePath.rawValue
            ]
        case .configAlias:
            allowedKeys = [
                CodingKeys.mode.rawValue,
                CodingKeys.alias.rawValue
            ]
        }

        try rejectUnknownKeys(
            from: decoder,
            allowedKeys: allowedKeys,
            context: "SSH session payload"
        )

        switch mode {
        case .direct:
            self = .direct(
                host: try container.decode(String.self, forKey: .host),
                port: try container.decode(Int.self, forKey: .port),
                user: try container.decode(String.self, forKey: .user),
                identityFilePath: try container.decodeIfPresent(
                    String.self,
                    forKey: .identityFilePath
                )
            )

        case .configAlias:
            self = .configAlias(
                alias: try container.decode(String.self, forKey: .alias)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case let .direct(host, port, user, identityFilePath):
            try container.encode(Mode.direct, forKey: .mode)
            try container.encode(host, forKey: .host)
            try container.encode(port, forKey: .port)
            try container.encode(user, forKey: .user)
            if let identityFilePath {
                try container.encode(identityFilePath, forKey: .identityFilePath)
            } else {
                try container.encodeNil(forKey: .identityFilePath)
            }

        case .configAlias(let alias):
            try container.encode(Mode.configAlias, forKey: .mode)
            try container.encode(alias, forKey: .alias)
        }
    }

    private enum Mode: String, Codable {
        case direct
        case configAlias
    }

    private enum CodingKeys: String, CodingKey {
        case mode
        case host
        case port
        case user
        case identityFilePath
        case alias
    }
}

private struct SessionProfileDynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

private func rejectUnknownKeys(
    from decoder: Decoder,
    allowedKeys: Set<String>,
    context: String
) throws {
    let container = try decoder.container(keyedBy: SessionProfileDynamicCodingKey.self)
    let unknownKey = container.allKeys
        .filter { !allowedKeys.contains($0.stringValue) }
        .sorted { $0.stringValue < $1.stringValue }
        .first

    guard let unknownKey else {
        return
    }

    throw DecodingError.dataCorruptedError(
        forKey: unknownKey,
        in: container,
        debugDescription: "Unknown key in \(context): \(unknownKey.stringValue)"
    )
}
