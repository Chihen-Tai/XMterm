import Foundation
import XMtermCore

enum OpenSSHSFTPTargetError: Error, Equatable, Sendable {
    case invalidHost
    case invalidUser
    case invalidPort(Int)
    case invalidIdentityFilePath
    case invalidAlias
}

struct OpenSSHSFTPTarget: Equatable, Sendable {
    let executablePath = "/usr/bin/ssh"
    let arguments: [String]

    init(profile: SSHSessionProfile) throws {
        arguments = switch profile {
        case let .direct(host, port, user, identityFilePath):
            try Self.directArguments(
                host: host,
                port: port,
                user: user,
                identityFilePath: identityFilePath
            )
        case .configAlias(let alias):
            try Self.aliasArguments(alias: alias)
        }
    }

    private static func directArguments(
        host: String,
        port: Int,
        user: String,
        identityFilePath: String?
    ) throws -> [String] {
        guard isSafeArgument(host), !host.contains("@") else {
            throw OpenSSHSFTPTargetError.invalidHost
        }
        guard isSafeArgument(user), !user.contains("@") else {
            throw OpenSSHSFTPTargetError.invalidUser
        }
        guard (1...65_535).contains(port) else {
            throw OpenSSHSFTPTargetError.invalidPort(port)
        }
        if let identityFilePath {
            guard identityFilePath.hasPrefix("/"),
                  !identityFilePath.unicodeScalars.contains(where: isControl) else {
                throw OpenSSHSFTPTargetError.invalidIdentityFilePath
            }
        }

        let identityArguments = identityFilePath.map { ["-i", $0] } ?? []
        return ["-T", "-o", "BatchMode=yes"]
            + identityArguments
            + ["-s", "-p", String(port), "\(user)@\(host)", "sftp"]
    }

    private static func aliasArguments(alias: String) throws -> [String] {
        guard isSafeArgument(alias) else {
            throw OpenSSHSFTPTargetError.invalidAlias
        }
        return ["-T", "-o", "BatchMode=yes", "-s", alias, "sftp"]
    }

    private static func isSafeArgument(_ value: String) -> Bool {
        !value.isEmpty
            && !value.hasPrefix("-")
            && !value.unicodeScalars.contains { scalar in
                CharacterSet.whitespacesAndNewlines.contains(scalar) || isControl(scalar)
            }
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .control
    }
}
