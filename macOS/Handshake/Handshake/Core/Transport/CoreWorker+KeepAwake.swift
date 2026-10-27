import Foundation
import HandshakeCore

extension CoreWorker {
    func keepAwake(_ enabled: Bool?) throws -> Bool {
        let operation: UInt32 = enabled.map { $0 ? 1 : 2 } ?? 0
        var output = HandshakeBuffer()
        try check(handshake_keep_awake(operation, &output))
        let response = try JSONDecoder().decode(KeepAwakeResponse.self, from: consume(&output))
        if let error = response.error { throw CoreFailure.failed(error) }
        guard let enabled = response.enabled else { throw CoreFailure.unexpectedCommandResult }
        return enabled
    }
}

private nonisolated struct KeepAwakeResponse: Decodable {
    let enabled: Bool?
    let error: String?
}
