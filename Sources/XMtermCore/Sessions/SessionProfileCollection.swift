import Foundation

public struct SessionProfileCollection: Equatable, Sendable {
    public let profiles: [SessionProfile]

    public var favoriteProfileIDs: [SessionProfileID] {
        profiles.filter(\.favorite).map(\.id)
    }

    public init() {
        profiles = []
    }

    public init(profiles: [SessionProfile]) throws {
        if let duplicateID = Self.firstDuplicateID(in: profiles) {
            throw SessionProfileCollectionError.duplicateIdentifier(duplicateID)
        }
        self.profiles = try profiles.map { profile in
            try SessionProfileValidator.validatedProfile(profile)
        }
    }

    public static func builtInDefaults(
        localID: SessionProfileID,
        relayID: SessionProfileID,
        seedDate: Date
    ) throws -> Self {
        let local = SessionProfile(
            id: localID,
            name: "Local Terminal",
            favorite: false,
            createdAt: seedDate,
            updatedAt: seedDate,
            lastOpenedAt: nil,
            sortOrder: 0,
            configuration: .local(
                LocalSessionProfile(
                    useLoginShell: true,
                    shellPath: nil,
                    workingDirectory: nil
                )
            )
        )
        let relay = SessionProfile(
            id: relayID,
            name: "Relay Host",
            favorite: false,
            createdAt: seedDate,
            updatedAt: seedDate,
            lastOpenedAt: nil,
            sortOrder: 1,
            configuration: .ssh(
                .direct(
                    host: "140.109.226.155",
                    port: 54_426,
                    user: "allen921103",
                    identityFilePath: nil
                )
            )
        )
        return try Self(profiles: [local, relay])
    }

    public func creating(
        from draft: SessionProfileDraft,
        id: SessionProfileID,
        createdAt: Date,
        updatedAt: Date
    ) throws -> Self {
        try requireUnique(id)
        let profile = try SessionProfileValidator.validatedProfile(
            from: draft,
            id: id,
            createdAt: createdAt,
            updatedAt: updatedAt,
            lastOpenedAt: nil,
            sortOrder: try nextSortOrder()
        )
        return Self(uncheckedProfiles: profiles + [profile])
    }

    public func inserting(_ profile: SessionProfile) throws -> Self {
        try requireUnique(profile.id)
        let validatedProfile = try SessionProfileValidator.validatedProfile(profile)
        return Self(uncheckedProfiles: profiles + [validatedProfile])
    }

    public func editing(
        id: SessionProfileID,
        with draft: SessionProfileDraft,
        updatedAt: Date
    ) throws -> Self {
        let index = try index(of: id)
        let existing = profiles[index]
        let replacement = try SessionProfileValidator.validatedProfile(
            from: draft,
            id: existing.id,
            createdAt: existing.createdAt,
            updatedAt: updatedAt,
            lastOpenedAt: existing.lastOpenedAt,
            sortOrder: existing.sortOrder
        )
        return replacingProfile(at: index, with: replacement)
    }

    public func renaming(
        id: SessionProfileID,
        to name: String,
        updatedAt: Date
    ) throws -> Self {
        let index = try index(of: id)
        let existing = profiles[index]
        let existingDraft = SessionProfileValidator.editingDraft(from: existing)
        let renamedDraft = SessionProfileDraft(
            name: name,
            favorite: existingDraft.favorite,
            kind: existingDraft.kind,
            local: existingDraft.local,
            ssh: existingDraft.ssh
        )
        let replacement = try SessionProfileValidator.validatedProfile(
            from: renamedDraft,
            id: existing.id,
            createdAt: existing.createdAt,
            updatedAt: updatedAt,
            lastOpenedAt: existing.lastOpenedAt,
            sortOrder: existing.sortOrder
        )
        return replacingProfile(at: index, with: replacement)
    }

    public func duplicating(
        id: SessionProfileID,
        newID: SessionProfileID,
        createdAt: Date,
        updatedAt: Date
    ) throws -> Self {
        let source = profiles[try index(of: id)]
        try requireUnique(newID)
        let duplicate = try SessionProfileValidator.validatedProfile(
            SessionProfile(
                id: newID,
                name: "\(source.name) Copy",
                favorite: false,
                createdAt: createdAt,
                updatedAt: updatedAt,
                lastOpenedAt: nil,
                sortOrder: try nextSortOrder(),
                configuration: source.configuration
            )
        )
        return Self(uncheckedProfiles: profiles + [duplicate])
    }

    public func deleting(id: SessionProfileID) throws -> Self {
        _ = try index(of: id)
        return Self(uncheckedProfiles: profiles.filter { $0.id != id })
    }

    public func settingFavorite(
        _ favorite: Bool,
        for id: SessionProfileID,
        updatedAt: Date
    ) throws -> Self {
        let index = try index(of: id)
        let existing = profiles[index]
        guard existing.favorite != favorite else { return self }

        return replacingProfile(
            at: index,
            with: copy(
                existing,
                favorite: favorite,
                updatedAt: updatedAt,
                lastOpenedAt: existing.lastOpenedAt
            )
        )
    }

    public func recordingOpened(
        id: SessionProfileID,
        at date: Date
    ) throws -> Self {
        let index = try index(of: id)
        let existing = profiles[index]
        return replacingProfile(
            at: index,
            with: copy(
                existing,
                favorite: existing.favorite,
                updatedAt: date,
                lastOpenedAt: date
            )
        )
    }

    public func recentProfileIDs(limit: Int = 8) -> [SessionProfileID] {
        guard limit > 0 else { return [] }

        return profiles
            .compactMap { profile -> (profile: SessionProfile, openedAt: Date)? in
                guard let openedAt = profile.lastOpenedAt else { return nil }
                return (profile, openedAt)
            }
            .sorted { left, right in
                if left.openedAt != right.openedAt {
                    return left.openedAt > right.openedAt
                }
                if left.profile.sortOrder != right.profile.sortOrder {
                    return left.profile.sortOrder < right.profile.sortOrder
                }
                return left.profile.id.rawValue.uuidString < right.profile.id.rawValue.uuidString
            }
            .prefix(limit)
            .map { $0.profile.id }
    }

    private init(uncheckedProfiles: [SessionProfile]) {
        profiles = uncheckedProfiles
    }

    private func requireUnique(_ id: SessionProfileID) throws {
        guard !profiles.contains(where: { $0.id == id }) else {
            throw SessionProfileCollectionError.duplicateIdentifier(id)
        }
    }

    private func index(of id: SessionProfileID) throws -> Int {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else {
            throw SessionProfileCollectionError.profileNotFound(id)
        }
        return index
    }

    private func nextSortOrder() throws -> Int {
        guard let maximum = profiles.map(\.sortOrder).max() else { return 0 }
        guard maximum < Int.max else {
            throw SessionProfileCollectionError.sortOrderExhausted
        }
        return maximum + 1
    }

    private func replacingProfile(at index: Int, with profile: SessionProfile) -> Self {
        Self(
            uncheckedProfiles: profiles.enumerated().map { currentIndex, currentProfile in
                currentIndex == index ? profile : currentProfile
            }
        )
    }

    private func copy(
        _ profile: SessionProfile,
        favorite: Bool,
        updatedAt: Date,
        lastOpenedAt: Date?
    ) -> SessionProfile {
        SessionProfile(
            id: profile.id,
            name: profile.name,
            favorite: favorite,
            createdAt: profile.createdAt,
            updatedAt: updatedAt,
            lastOpenedAt: lastOpenedAt,
            sortOrder: profile.sortOrder,
            configuration: profile.configuration
        )
    }

    private static func firstDuplicateID(
        in profiles: [SessionProfile]
    ) -> SessionProfileID? {
        profiles.enumerated().first { index, profile in
            profiles[..<index].contains(where: { $0.id == profile.id })
        }?.element.id
    }
}

public enum SessionProfileCollectionError: Error, Equatable, Sendable {
    case duplicateIdentifier(SessionProfileID)
    case profileNotFound(SessionProfileID)
    case sortOrderExhausted
}
