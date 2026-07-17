import XMtermCore

enum SessionProfileLaunchPolicy {
    static func defaultLocalProfileID(
        in collection: SessionProfileCollection
    ) -> SessionProfileID? {
        collection.profiles
            .sorted { left, right in
                if left.sortOrder != right.sortOrder {
                    return left.sortOrder < right.sortOrder
                }
                return left.id.rawValue.uuidString < right.id.rawValue.uuidString
            }
            .first { profile in
                guard case .local(let local) = profile.configuration else { return false }
                return local.useLoginShell
            }?
            .id
    }
}
