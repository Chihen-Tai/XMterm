import Foundation
import XMtermCore

package struct OpenSSHRemoteTransferTrustedConnectionMaterial:
    RemoteTransferTrustedConnectionMaterial
{
    package let profile: SSHSessionProfile
    package let retainedByteCount: Int

    package init(profile: SSHSessionProfile) throws {
        let byteCounts: [Int] = switch profile {
        case let .direct(host, _, user, identityFilePath):
            [host.utf8.count, user.utf8.count, identityFilePath?.utf8.count ?? 0]
        case let .configAlias(alias):
            [alias.utf8.count]
        }
        retainedByteCount = try byteCounts.reduce(0) {
            try RemoteTransferAggregateCounts.checkedSum($0, $1)
        }
        guard retainedByteCount <= RemoteTransferBounds.maximumJobRetainedByteCount else {
            throw RemoteFileError(category: .limitExceeded)
        }
        self.profile = profile
    }
}

public struct OpenSSHSFTPTransferProviderFactory: RemoteTransferEndpointProviderFactory {
    public init() {}

    package static func endpointSnapshot(
        profile: SSHSessionProfile,
        owner: RemoteTransferOwnerIdentity,
        displayName: String,
        id: UUID = UUID()
    ) throws -> RemoteTransferEndpointSnapshot {
        try RemoteTransferEndpointSnapshot(
            id: id,
            owner: owner,
            summary: RemoteTransferEndpointSummary(
                displayName: RemoteTransferPresentationText(displayName),
                kind: .openSSH
            ),
            trustedConnectionMaterial: OpenSSHRemoteTransferTrustedConnectionMaterial(
                profile: profile
            )
        )
    }

    public func makeProvider(
        for endpoint: RemoteTransferEndpointSnapshot
    ) async throws -> any RemoteTransferEndpointProvider {
        guard endpoint.summary.kind == .openSSH,
              let material = endpoint.trustedConnectionMaterial
                as? OpenSSHRemoteTransferTrustedConnectionMaterial else {
            throw RemoteFileError(category: .invalidOperation)
        }
        return try OpenSSHSFTPRemoteFileProvider(profile: material.profile)
    }
}
