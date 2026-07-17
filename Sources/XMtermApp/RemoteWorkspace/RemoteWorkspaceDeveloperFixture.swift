import Foundation
import XMtermRemote

/// Explicit, opt-in developer injection for packaged-app foundation verification.
///
/// The shipping composition always receives the honest
/// `UnavailableRemoteFileProvider`. Only the exact environment value
/// `XMTERM_REMOTE_WORKSPACE_FIXTURE=simulated` swaps in a deterministic in-memory
/// graph, every listing of which is labeled simulated. Nothing here contacts a
/// real host, and the fixture must never be presented as Relay Host evidence.
enum RemoteWorkspaceDeveloperFixture {
    static let environmentKey = "XMTERM_REMOTE_WORKSPACE_FIXTURE"
    static let simulatedValue = "simulated"
    static let capabilityNotes =
        "Simulated in-memory developer fixture listing. This is not a real remote host."

    static func isEnabled(environment: [String: String]) -> Bool {
        environment[environmentKey] == simulatedValue
    }

    static func provider(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> any RemoteFileProvider {
        guard isEnabled(environment: environment) else {
            return UnavailableRemoteFileProvider()
        }
        do {
            return try simulatedProvider()
        } catch {
            // Fail closed into the honest transport-unavailable state rather than
            // presenting a partially built simulated graph.
            return UnavailableRemoteFileProvider()
        }
    }

    static func simulatedProvider() throws -> InMemoryRemoteFileProvider {
        let root = try path("/simulated")
        var graph: [RemotePath: InMemoryRemoteFileProvider.Directory] = [:]

        graph[RemotePath.root] = try listing(entries: [
            entry("/simulated", kind: .directory, permissions: 0o755)
        ])

        graph[root] = try listing(entries: [
            entry("/simulated/home", kind: .directory, permissions: 0o755),
            entry("/simulated/large", kind: .directory, permissions: 0o755),
            entry("/simulated/empty", kind: .directory, permissions: 0o755),
            entry("/simulated/denied", kind: .directory, permissions: 0o000),
            entry("/simulated/測試資料", kind: .directory, permissions: 0o755),
            entry("/simulated/README.md", kind: .regular, size: 2_048, permissions: 0o644),
            entry("/simulated/o'brien's notes.txt", kind: .regular, size: 640),
            entry("/simulated/🚀 launch plans.txt", kind: .regular, size: 1_280),
            entry("/simulated/-leading-dash.txt", kind: .regular, size: 96),
            entry("/simulated/.hidden-config", kind: .regular, size: 512),
            entry("/simulated/run.sh", kind: .regular, size: 320, permissions: 0o755),
            entry(
                "/simulated/link-to-home",
                kind: .symbolicLink,
                symbolicLinkTarget: "/simulated/home"
            )
        ])

        graph[try path("/simulated/home")] = try listing(entries: [
            entry("/simulated/home/projects", kind: .directory, permissions: 0o755),
            entry("/simulated/home/todo.txt", kind: .regular, size: 220, permissions: 0o644)
        ])

        graph[try path("/simulated/home/projects")] = try listing(entries: [
            entry(
                "/simulated/home/projects/xmterm-notes.txt",
                kind: .regular,
                size: 4_096,
                permissions: 0o644
            )
        ])

        graph[try path("/simulated/large")] = try listing(entries: largeEntries())
        graph[try path("/simulated/empty")] = try listing(entries: [])
        graph[try path("/simulated/測試資料")] = try listing(entries: [
            entry("/simulated/測試資料/資料.txt", kind: .regular, size: 88)
        ])

        return InMemoryRemoteFileProvider(
            initialDirectory: root,
            directoryGraph: graph,
            deterministicResponses: .init(
                listings: [
                    try path("/simulated/denied"): .failure(
                        RemoteFileError(category: .permissionDenied)
                    )
                ]
            ),
            latency: .milliseconds(250)
        )
    }

    private static func largeEntries() throws -> [RemoteFileEntry] {
        try (0..<1_000).map { index in
            if index.isMultiple(of: 10) {
                try entry(
                    String(format: "/simulated/large/folder-%03d", index / 10),
                    kind: .directory,
                    permissions: 0o755
                )
            } else {
                try entry(
                    String(format: "/simulated/large/file-%04d.txt", index),
                    kind: .regular,
                    size: UInt64(index) * 37,
                    permissions: index.isMultiple(of: 3) ? 0o644 : nil
                )
            }
        }
    }

    private static func listing(
        entries: [RemoteFileEntry]
    ) throws -> InMemoryRemoteFileProvider.Directory {
        InMemoryRemoteFileProvider.Directory(
            entries: entries,
            metadataCompleteness: .partial,
            providerCapabilityNotes: capabilityNotes
        )
    }

    private static func entry(
        _ rawPath: String,
        kind: RemoteFileEntry.Kind,
        size: UInt64? = nil,
        permissions: UInt16? = nil,
        symbolicLinkTarget: String? = nil
    ) throws -> RemoteFileEntry {
        try RemoteFileEntry(
            path: path(rawPath),
            kind: kind,
            size: size,
            modificationDate: Date(timeIntervalSince1970: 1_752_000_000),
            permissions: permissions,
            symbolicLinkTarget: symbolicLinkTarget.map {
                try RemoteSymlinkTarget(rawBytes: Array($0.utf8))
            },
            metadataCompleteness: permissions == nil ? .partial : .complete
        )
    }

    private static func path(_ value: String) throws -> RemotePath {
        try RemotePath(rawBytes: Array(value.utf8))
    }
}
