import Foundation

extension CoreClient {
    func featureFlags() async throws -> FeatureFlagSnapshot { try await transport.featureFlags() }

    func setFeatureFlag(
        _ id: FeatureFlagID, enabled: Bool, expectedVersion: FileVersion
    ) async throws -> FileSaveResult {
        try await transport.setFeatureFlag(id, enabled: enabled, expectedVersion: expectedVersion)
    }
}
