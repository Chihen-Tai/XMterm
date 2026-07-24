import Foundation
import XMtermCore
import XMtermRemote

enum RemoteWorkspaceProductionComposition {
    static func composition(
        for profile: SSHSessionProfile,
        owner: RemoteTransferOwnerIdentity = RemoteTransferOwnerIdentity(
            runtimeID: TerminalSessionID(),
            workspaceID: RemoteWorkspaceID()
        ),
        displayName: String = "OpenSSH transfer endpoint",
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isDeveloperBuild: Bool = RemoteWorkspaceDeveloperFixture.isDeveloperBuild
    ) -> RemoteProviderComposition {
        if isDeveloperBuild,
           RemoteWorkspaceDeveloperFixture.isEnabled(environment: environment) {
            return RemoteWorkspaceDeveloperFixture.composition(
                owner: owner,
                displayName: displayName,
                environment: environment,
                isDeveloperBuild: true
            )
        }
        do {
            return try .production(
                profile: profile,
                owner: owner,
                displayName: displayName
            )
        } catch {
            return .unavailable(owner: owner)
        }
    }
}
