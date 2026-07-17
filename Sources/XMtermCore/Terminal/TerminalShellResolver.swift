import Foundation

package struct ResolvedTerminalShell: Equatable, Sendable {
    public let executablePath: String
    public let argumentZero: String
    public let arguments: [String]
    public let workingDirectory: String

    package init(
        executablePath: String,
        argumentZero: String,
        arguments: [String],
        workingDirectory: String
    ) {
        self.executablePath = executablePath
        self.argumentZero = argumentZero
        self.arguments = arguments
        self.workingDirectory = workingDirectory
    }
}

package enum TerminalShellResolver {
    public static func resolve(
        accountShell: String?,
        environmentShell: String?,
        fallbackShell: String = "/bin/zsh",
        userHomeDirectory: String,
        isUsableExecutableFile: (String) -> Bool
    ) throws -> ResolvedTerminalShell {
        let candidates = [accountShell, environmentShell, fallbackShell]
            .compactMap { candidate -> String? in
                guard let candidate else { return nil }
                let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }

        guard let executablePath = candidates.first(where: {
            $0.hasPrefix("/") && isUsableExecutableFile($0)
        }) else {
            throw TerminalShellResolutionError.shellUnavailable
        }

        let shellName = URL(fileURLWithPath: executablePath).lastPathComponent
        guard !shellName.isEmpty else {
            throw TerminalShellResolutionError.shellUnavailable
        }

        return ResolvedTerminalShell(
            executablePath: executablePath,
            argumentZero: "-\(shellName)",
            arguments: [],
            workingDirectory: userHomeDirectory
        )
    }

}

package enum TerminalShellResolutionError: Error, Equatable, Sendable {
    case shellUnavailable
}
