import Foundation
import HandshakeCore

private nonisolated struct MigrationResult: Decodable { let error: String? }

extension CoreWorker {
    /// Actor isolation keeps synchronous filesystem/SQLite migration off the UI actor.
    func migrateData(from legacy: URL, to destination: URL) throws {
        let legacy = Array(legacy.path(percentEncoded: false).utf8)
        let destination = Array(destination.path(percentEncoded: false).utf8)
        var response = HandshakeBuffer()
        let status = legacy.withUnsafeBufferPointer { source in
            destination.withUnsafeBufferPointer { target in
                handshake_migrate_data(source.baseAddress, source.count, target.baseAddress, target.count, &response)
            }
        }
        try check(status)
        let result = try JSONDecoder().decode(MigrationResult.self, from: consume(&response))
        if let error = result.error { throw CoreFailure.failed(error) }
    }
}
