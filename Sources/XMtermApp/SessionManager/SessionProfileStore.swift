import Foundation
import Observation
import XMtermCore

enum SessionProfileStoreState: Equatable, Sendable {
    case loading
    case content
    case recoveryRequired
    case error
}

enum SessionProfileStoreFailure: Equatable, Sendable {
    case load
    case persistence
    case validation(SessionProfileValidationError)
    case pathValidation(
        profileID: SessionProfileID?,
        issues: [SessionProfilePathIssue]
    )
    case profileNotFound
    case recoveryActionRequired
    case operationUnavailable
    case internalConsistency

    var userMessage: String {
        switch self {
        case .load:
            "XMterm couldn’t load saved sessions. Try again."
        case .persistence:
            "XMterm couldn’t save session changes. Your previous sessions are unchanged."
        case .validation:
            "Review the highlighted session fields."
        case .pathValidation(_, let issues):
            Self.pathValidationMessage(for: issues)
        case .profileNotFound:
            "That saved session is no longer available."
        case .recoveryActionRequired:
            "Choose a recovery action before changing saved sessions."
        case .operationUnavailable:
            "Another saved-session operation is still in progress."
        case .internalConsistency:
            "XMterm couldn’t apply that saved-session change."
        }
    }

    private static func pathValidationMessage(
        for issues: [SessionProfilePathIssue]
    ) -> String {
        let fields = Set(issues.map(\.field))
        guard fields.count == 1, let field = fields.first else {
            return "One or more saved session paths are unavailable. Edit the profile to repair the highlighted fields."
        }

        switch field {
        case .shellPath:
            return "The saved shell executable is unavailable. Edit the profile to repair the highlighted field."
        case .workingDirectory:
            return "The saved working directory is unavailable. Edit the profile to repair the highlighted field."
        case .identityFilePath:
            return "The saved identity file is unavailable. Edit the profile to repair the highlighted field."
        default:
            return "A saved session path is unavailable. Edit the profile to repair the highlighted field."
        }
    }
}

@MainActor
@Observable
final class SessionProfileStore {
    private(set) var state: SessionProfileStoreState = .loading
    private(set) var collection = SessionProfileCollection()
    private(set) var recovery: SessionProfileRecovery?
    private(set) var lastFailure: SessionProfileStoreFailure?
    private(set) var isMutating = false
    private(set) var isValidatingLaunch = false

    @ObservationIgnored private let repository: any SessionProfileRepository
    @ObservationIgnored private let pathInspector: any SessionProfilePathInspecting
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let idSource: () -> SessionProfileID
    @ObservationIgnored private var recoveryDefaultCandidate: SessionProfileCollection?
    @ObservationIgnored private var isLoading = false

    var profiles: [SessionProfile] {
        collection.profiles
    }

    var canMutateProfiles: Bool {
        state == .content && !isLoading && !isMutating && !isValidatingLaunch
    }

    var canLaunchProfiles: Bool {
        state == .content && !isLoading && !isMutating && !isValidatingLaunch
    }

    init(
        repository: any SessionProfileRepository,
        pathInspector: any SessionProfilePathInspecting = FoundationSessionProfilePathInspector(),
        clock: @escaping () -> Date = Date.init,
        idSource: @escaping () -> SessionProfileID = SessionProfileID.init
    ) {
        self.repository = repository
        self.pathInspector = pathInspector
        self.clock = clock
        self.idSource = idSource
    }

    static func live() -> SessionProfileStore {
        do {
            return SessionProfileStore(repository: try JSONSessionProfileRepository.live())
        } catch {
            return SessionProfileStore(repository: UnavailableSessionProfileRepository())
        }
    }

    func load() async {
        guard !isLoading, !isMutating, !isValidatingLaunch else {
            lastFailure = .operationUnavailable
            return
        }

        isLoading = true
        state = .loading
        lastFailure = nil
        defer { isLoading = false }

        do {
            let result = try await repository.load()
            switch result {
            case .uninitialized:
                await seedFirstLaunch()

            case .loaded(let loadedCollection):
                publishContent(loadedCollection)

            case .recoveryRequired(let recovery):
                publishRecovery(recovery)
            }
        } catch {
            state = .error
            lastFailure = .load
        }
    }

    func create(from draft: SessionProfileDraft) async -> Bool {
        guard beginContentMutation() else { return false }
        defer { isMutating = false }

        do {
            let identifier = idSource()
            let date = clock()
            let proposed = try collection.creating(
                from: draft,
                id: identifier,
                createdAt: date,
                updatedAt: date
            )
            guard let profile = proposed.profiles.first(where: { $0.id == identifier }) else {
                lastFailure = .internalConsistency
                return false
            }
            guard await validatePaths(for: profile, failureProfileID: nil) else {
                return false
            }
            return await persist(proposed)
        } catch {
            return handleMutationError(error)
        }
    }

    func edit(
        id: SessionProfileID,
        with draft: SessionProfileDraft
    ) async -> Bool {
        guard beginContentMutation() else { return false }
        defer { isMutating = false }

        do {
            let proposed = try collection.editing(
                id: id,
                with: draft,
                updatedAt: clock()
            )
            guard let profile = proposed.profiles.first(where: { $0.id == id }) else {
                lastFailure = .internalConsistency
                return false
            }
            guard await validatePaths(for: profile, failureProfileID: id) else {
                return false
            }
            return await persist(proposed)
        } catch {
            return handleMutationError(error)
        }
    }

    func rename(id: SessionProfileID, to name: String) async -> Bool {
        await mutateCollection {
            try $0.renaming(id: id, to: name, updatedAt: clock())
        }
    }

    func duplicate(id: SessionProfileID) async -> Bool {
        guard beginContentMutation() else { return false }
        defer { isMutating = false }

        do {
            let newID = idSource()
            let date = clock()
            let proposed = try collection.duplicating(
                id: id,
                newID: newID,
                createdAt: date,
                updatedAt: date
            )
            guard let duplicate = proposed.profiles.first(where: { $0.id == newID }) else {
                lastFailure = .internalConsistency
                return false
            }
            guard await validatePaths(for: duplicate, failureProfileID: id) else {
                return false
            }
            return await persist(proposed)
        } catch {
            return handleMutationError(error)
        }
    }

    func delete(id: SessionProfileID) async -> Bool {
        await mutateCollection { try $0.deleting(id: id) }
    }

    func setFavorite(_ favorite: Bool, for id: SessionProfileID) async -> Bool {
        await mutateCollection {
            try $0.settingFavorite(favorite, for: id, updatedAt: clock())
        }
    }

    func recordOpened(id: SessionProfileID) async -> Bool {
        await mutateCollection { try $0.recordingOpened(id: id, at: clock()) }
    }

    /// Explicit launch boundary for structural and filesystem validation.
    /// Draft typing never calls this method.
    func profileReadyForLaunch(id: SessionProfileID) async -> SessionProfile? {
        guard state == .content else {
            lastFailure = state == .recoveryRequired
                ? .recoveryActionRequired
                : .operationUnavailable
            return nil
        }
        guard !isLoading, !isMutating, !isValidatingLaunch else {
            lastFailure = .operationUnavailable
            return nil
        }
        guard let profile = profiles.first(where: { $0.id == id }) else {
            lastFailure = .profileNotFound
            return nil
        }

        isValidatingLaunch = true
        lastFailure = nil
        defer { isValidatingLaunch = false }

        do {
            _ = try SessionProfileValidator.validatedProfile(profile)
        } catch {
            _ = handleMutationError(error)
            return nil
        }
        guard await validatePaths(for: profile, failureProfileID: id) else {
            return nil
        }
        return profile
    }

    func useRecoveredProfiles() async -> Bool {
        guard let recovery, beginRecoveryMutation() else { return false }
        defer { isMutating = false }

        return await persistRecovery(recovery.recoveredCollection)
    }

    func resetToDefaults() async -> Bool {
        guard recovery != nil, beginRecoveryMutation() else { return false }
        defer { isMutating = false }

        do {
            let defaults = try recoveryDefaultCandidate ?? makeDefaults()
            return await persistRecovery(defaults)
        } catch {
            lastFailure = .internalConsistency
            return false
        }
    }

    func clearFailure() {
        lastFailure = nil
    }

    private func seedFirstLaunch() async {
        do {
            let defaults = try makeDefaults()
            do {
                try await repository.save(defaults)
                publishContent(defaults)
            } catch {
                state = .error
                lastFailure = .persistence
            }
        } catch {
            state = .error
            lastFailure = .internalConsistency
        }
    }

    private func publishContent(_ newCollection: SessionProfileCollection) {
        collection = newCollection
        recovery = nil
        recoveryDefaultCandidate = nil
        state = .content
        lastFailure = nil
    }

    private func publishRecovery(_ newRecovery: SessionProfileRecovery) {
        do {
            let defaults = try makeDefaults()
            collection = newRecovery.recoveredCollection.profiles.isEmpty
                ? defaults
                : newRecovery.recoveredCollection
            recoveryDefaultCandidate = defaults
            recovery = newRecovery
            state = .recoveryRequired
            lastFailure = nil
        } catch {
            state = .error
            lastFailure = .internalConsistency
        }
    }

    private func makeDefaults() throws -> SessionProfileCollection {
        try SessionProfileCollection.builtInDefaults(
            localID: idSource(),
            relayID: idSource(),
            seedDate: clock()
        )
    }

    private func beginContentMutation() -> Bool {
        guard state == .content else {
            lastFailure = state == .recoveryRequired
                ? .recoveryActionRequired
                : .operationUnavailable
            return false
        }
        guard !isLoading, !isMutating, !isValidatingLaunch else {
            lastFailure = .operationUnavailable
            return false
        }
        isMutating = true
        lastFailure = nil
        return true
    }

    private func beginRecoveryMutation() -> Bool {
        guard state == .recoveryRequired else {
            lastFailure = .operationUnavailable
            return false
        }
        guard !isLoading, !isMutating, !isValidatingLaunch else {
            lastFailure = .operationUnavailable
            return false
        }
        isMutating = true
        lastFailure = nil
        return true
    }

    private func mutateCollection(
        _ transform: (SessionProfileCollection) throws -> SessionProfileCollection
    ) async -> Bool {
        guard beginContentMutation() else { return false }
        defer { isMutating = false }

        do {
            return await persist(try transform(collection))
        } catch {
            return handleMutationError(error)
        }
    }

    private func validatePaths(
        for profile: SessionProfile,
        failureProfileID: SessionProfileID?
    ) async -> Bool {
        let issues = await pathInspector.inspect(profile)
        guard issues.isEmpty else {
            lastFailure = .pathValidation(
                profileID: failureProfileID,
                issues: issues
            )
            return false
        }
        return true
    }

    private func persist(_ proposed: SessionProfileCollection) async -> Bool {
        do {
            try await repository.save(proposed)
            collection = proposed
            lastFailure = nil
            return true
        } catch {
            lastFailure = .persistence
            return false
        }
    }

    private func persistRecovery(_ proposed: SessionProfileCollection) async -> Bool {
        do {
            try await repository.save(proposed)
            publishContent(proposed)
            return true
        } catch {
            lastFailure = .persistence
            return false
        }
    }

    private func handleMutationError(_ error: Error) -> Bool {
        if let validationError = error as? SessionProfileValidationError {
            lastFailure = .validation(validationError)
            return false
        }
        if let collectionError = error as? SessionProfileCollectionError {
            switch collectionError {
            case .profileNotFound:
                lastFailure = .profileNotFound
            case .duplicateIdentifier, .sortOrderExhausted:
                lastFailure = .internalConsistency
            }
            return false
        }
        lastFailure = .internalConsistency
        return false
    }
}

private actor UnavailableSessionProfileRepository: SessionProfileRepository {
    func load() async throws -> SessionProfileLoadResult {
        throw SessionProfileRepositoryError.applicationSupportDirectoryUnavailable
    }

    func save(_ collection: SessionProfileCollection) async throws {
        _ = collection
        throw SessionProfileRepositoryError.applicationSupportDirectoryUnavailable
    }
}
