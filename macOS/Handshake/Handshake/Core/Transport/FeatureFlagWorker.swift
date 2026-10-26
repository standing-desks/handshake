import Foundation
import HandshakeCore

extension CoreWorker {
    func featureFlags() throws -> FeatureFlagSnapshot {
        let response = try featureFlagRequest(FeatureFlagRequest(type: "read"))
        guard let snapshot = response.snapshot else { throw CoreFailure.unexpectedCommandResult }
        return snapshot
    }

    func setFeatureFlag(_ id: FeatureFlagID, enabled: Bool, expectedVersion: FileVersion) throws -> FileSaveResult {
        let response = try featureFlagRequest(
            FeatureFlagRequest(type: "set", id: id, enabled: enabled, expectedVersion: expectedVersion))
        guard let result = response.result else { throw CoreFailure.unexpectedCommandResult }
        return result
    }

    private func featureFlagRequest(_ request: FeatureFlagRequest) throws -> FeatureFlagResponse {
        let bytes = try JSONEncoder().encode(request)
        var output = HandshakeBuffer()
        let status = bytes.withUnsafeBytes {
            handshake_feature_flags($0.bindMemory(to: UInt8.self).baseAddress, $0.count, &output)
        }
        try check(status)
        let response = try JSONDecoder().decode(FeatureFlagResponse.self, from: consume(&output))
        if let error = response.error { throw CoreFailure.failed(error) }
        return response
    }
}
