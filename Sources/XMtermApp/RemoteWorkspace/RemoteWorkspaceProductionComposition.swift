import Foundation
import XMtermCore
import XMtermRemote

enum RemoteWorkspaceProductionComposition {
    static func composition(
        for profile: SSHSessionProfile,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isDeveloperBuild: Bool = RemoteWorkspaceDeveloperFixture.isDeveloperBuild
    ) -> RemoteProviderComposition {
        if isDeveloperBuild,
           RemoteWorkspaceDeveloperFixture.isEnabled(environment: environment) {
            return RemoteWorkspaceDeveloperFixture.composition(
                environment: environment,
                isDeveloperBuild: true
            )
        }
        do {
            return .production(try OpenSSHSFTPRemoteFileProvider(profile: profile))
        } catch {
            return .unavailable()
        }
    }
}
