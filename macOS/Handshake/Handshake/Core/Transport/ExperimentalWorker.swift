import Foundation
import HandshakeCore

extension CoreWorker {
    func experimental() throws -> ExperimentalSnapshot {
        let response = try experimentalRequest(ExperimentalRequest(type: "read"))
        guard let snapshot = response.snapshot else { throw CoreFailure.unexpectedCommandResult }
        return snapshot
    }

    func setExperimentalFeature(
        _ id: ExperimentalFeatureID, enabled: Bool, expectedVersion: FileVersion
    ) throws -> FileSaveResult {
        let response = try experimentalRequest(
            ExperimentalRequest(type: "set", id: id, enabled: enabled, expectedVersion: expectedVersion))
        guard let result = response.result else { throw CoreFailure.unexpectedCommandResult }
        return result
    }

    private func experimentalRequest(_ request: ExperimentalRequest) throws -> ExperimentalResponse {
        let bytes = try JSONEncoder().encode(request)
        var output = HandshakeBuffer()
        let status = bytes.withUnsafeBytes {
            handshake_experimental($0.bindMemory(to: UInt8.self).baseAddress, $0.count, &output)
        }
        try check(status)
        let response = try JSONDecoder().decode(ExperimentalResponse.self, from: consume(&output))
        if let error = response.error { throw CoreFailure.failed(error) }
        return response
    }
}
