import Foundation
import XMtermCore

enum SessionPickerSectionKind: String, CaseIterable, Equatable, Hashable, Sendable {
    case searchResults
    case recent
    case favorites
    case ssh
    case local

    var title: String {
        switch self {
        case .searchResults: "Results"
        case .recent: "Recent"
        case .favorites: "Favorites"
        case .ssh: "SSH"
        case .local: "Local"
        }
    }
}

struct SessionPickerSection: Identifiable, Equatable, Sendable {
    let kind: SessionPickerSectionKind
    let profileIDs: [SessionProfileID]

    var id: SessionPickerSectionKind { kind }
}

enum SessionPickerSelectionMove: Equatable, Sendable {
    case previous
    case next
}

struct SessionPickerModel: Equatable, Sendable {
    let collection: SessionProfileCollection
    let query: String
    let sections: [SessionPickerSection]
    let selectedProfileID: SessionProfileID?

    var orderedProfileIDs: [SessionProfileID] {
        sections.flatMap(\.profileIDs)
    }

    var launchProfileID: SessionProfileID? {
        guard let selectedProfileID,
              orderedProfileIDs.contains(selectedProfileID) else { return nil }
        return selectedProfileID
    }

    var isSearching: Bool {
        !Self.normalizedQuery(query).isEmpty
    }

    init(
        collection: SessionProfileCollection,
        query: String = "",
        selectedProfileID: SessionProfileID? = nil
    ) {
        self.collection = collection
        self.query = query
        sections = Self.makeSections(collection: collection, query: query)
        let visibleIDs = sections.flatMap(\.profileIDs)
        self.selectedProfileID = selectedProfileID.flatMap { candidate in
            visibleIDs.contains(candidate) ? candidate : nil
        } ?? visibleIDs.first
    }

    func profile(id: SessionProfileID) -> SessionProfile? {
        collection.profiles.first { $0.id == id }
    }

    func movingSelection(_ move: SessionPickerSelectionMove) -> Self {
        let visibleIDs = orderedProfileIDs
        guard !visibleIDs.isEmpty else { return self }
        let currentIndex = selectedProfileID.flatMap(visibleIDs.firstIndex) ?? 0
        let nextIndex = switch move {
        case .previous: max(0, currentIndex - 1)
        case .next: min(visibleIDs.count - 1, currentIndex + 1)
        }
        return Self(
            collection: collection,
            query: query,
            selectedProfileID: visibleIDs[nextIndex]
        )
    }

    func updatingQuery(_ query: String) -> Self {
        Self(
            collection: collection,
            query: query,
            selectedProfileID: selectedProfileID
        )
    }

    private static func makeSections(
        collection: SessionProfileCollection,
        query: String
    ) -> [SessionPickerSection] {
        let orderedProfiles = collection.profiles.sorted(by: profileOrder)
        let normalizedQuery = normalizedQuery(query)
        guard normalizedQuery.isEmpty else {
            let matchingIDs = orderedProfiles
                .filter { matches($0, query: normalizedQuery) }
                .map(\.id)
            guard !matchingIDs.isEmpty else { return [] }
            return [SessionPickerSection(kind: .searchResults, profileIDs: matchingIDs)]
        }

        var includedIDs = Set<SessionProfileID>()
        var sections: [SessionPickerSection] = []
        appendSection(
            .recent,
            ids: collection.recentProfileIDs(limit: 8),
            includedIDs: &includedIDs,
            sections: &sections
        )
        appendSection(
            .favorites,
            ids: orderedProfiles.filter(\.favorite).map(\.id),
            includedIDs: &includedIDs,
            sections: &sections
        )
        appendSection(
            .ssh,
            ids: orderedProfiles.compactMap { profile in
                guard case .ssh = profile.configuration else { return nil }
                return profile.id
            },
            includedIDs: &includedIDs,
            sections: &sections
        )
        appendSection(
            .local,
            ids: orderedProfiles.compactMap { profile in
                guard case .local = profile.configuration else { return nil }
                return profile.id
            },
            includedIDs: &includedIDs,
            sections: &sections
        )
        return sections
    }

    private static func appendSection(
        _ kind: SessionPickerSectionKind,
        ids: [SessionProfileID],
        includedIDs: inout Set<SessionProfileID>,
        sections: inout [SessionPickerSection]
    ) {
        let uniqueIDs = ids.filter { includedIDs.insert($0).inserted }
        guard !uniqueIDs.isEmpty else { return }
        sections.append(SessionPickerSection(kind: kind, profileIDs: uniqueIDs))
    }

    private static func matches(_ profile: SessionProfile, query: String) -> Bool {
        searchableValues(for: profile).contains { value in
            value.range(
                of: query,
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            ) != nil
        }
    }

    private static func searchableValues(for profile: SessionProfile) -> [String] {
        switch profile.configuration {
        case .local(let local):
            [profile.name, local.shellPath].compactMap { $0 }

        case .ssh(let ssh):
            switch ssh {
            case let .direct(host, _, user, _):
                [profile.name, host, user]
            case .configAlias(let alias):
                [profile.name, alias]
            }
        }
    }

    private static func normalizedQuery(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func profileOrder(_ left: SessionProfile, _ right: SessionProfile) -> Bool {
        if left.sortOrder != right.sortOrder {
            return left.sortOrder < right.sortOrder
        }
        return left.id.rawValue.uuidString < right.id.rawValue.uuidString
    }
}
