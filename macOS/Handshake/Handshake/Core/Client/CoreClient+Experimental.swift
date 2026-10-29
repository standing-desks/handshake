import Foundation

extension CoreClient {
    func experimental() async throws -> ExperimentalSnapshot { try await transport.experimental() }

    func setExperimentalFeature(
        _ id: ExperimentalFeatureID, enabled: Bool, expectedVersion: FileVersion
    ) async throws -> FileSaveResult {
        try await transport.setExperimentalFeature(id, enabled: enabled, expectedVersion: expectedVersion)
    }
}
