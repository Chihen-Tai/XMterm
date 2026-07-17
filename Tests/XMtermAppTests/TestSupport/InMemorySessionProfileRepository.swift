import Foundation
import XMtermCore
@testable import XMtermApp

actor InMemorySessionProfileRepository: SessionProfileRepository {
    enum TestError: Error {
        case loadFailed
        case saveFailed
    }

    private var result: SessionProfileLoadResult
    private var loadFailure = false
    private var saveFailure = false
    private var loadCount = 0
    private var savedValues: [SessionProfileCollection] = []

    init(result: SessionProfileLoadResult) {
        self.result = result
    }

    func load() async throws -> SessionProfileLoadResult {
        loadCount += 1
        guard !loadFailure else { throw TestError.loadFailed }
        return result
    }

    func save(_ collection: SessionProfileCollection) async throws {
        guard !saveFailure else { throw TestError.saveFailed }
        savedValues.append(collection)
        result = .loaded(collection)
    }

    func setLoadFailure(_ enabled: Bool) {
        loadFailure = enabled
    }

    func setSaveFailure(_ enabled: Bool) {
        saveFailure = enabled
    }

    func savedCollections() -> [SessionProfileCollection] {
        savedValues
    }

    func loadInvocationCount() -> Int {
        loadCount
    }
}

struct StubSessionProfilePathInspector: SessionProfilePathInspecting {
    let issues: [SessionProfilePathIssue]

    init(issues: [SessionProfilePathIssue] = []) {
        self.issues = issues
    }

    func inspect(_ profile: SessionProfile) async -> [SessionProfilePathIssue] {
        issues
    }
}
