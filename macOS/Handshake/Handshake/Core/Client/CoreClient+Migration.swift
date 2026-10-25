import Foundation

extension CoreClient {
    /// Explicit production bootstrap; callers construct all path-dependent presentation state
    /// only after this succeeds. Isolated launches have no legacy source and perform no migration.
    static func prepareDataDirectory(_ launch: AppPaths.Launch) async throws -> URL {
        if let legacy = launch.legacyDirectory {
            try await CoreWorker(dataDirectory: launch.dataDirectory).migrateData(
                from: legacy, to: launch.dataDirectory)
        }
        return launch.dataDirectory
    }
}
