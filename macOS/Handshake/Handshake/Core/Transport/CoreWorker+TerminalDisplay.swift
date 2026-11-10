import Foundation
import HandshakeCore

extension CoreWorker {
    func terminalDisplayCache(terminalID: UInt64, operation: CoreDisplayCacheOperation) async throws -> Data? {
        let key: UInt64
        let sourceOffset: UInt64
        let bytes: Data
        let code: UInt32
        switch operation {
        case .read(let value):
            (key, sourceOffset, bytes, code) = (value, 0, Data(), 0)
        case .write(let value, let offset, let data):
            (key, sourceOffset, bytes, code) = (value, offset, data, 1)
        }
        var pending: OpaquePointer?
        while pending == nil {
            try Task.checkCancellation()
            let status = try withClient { client in
                bytes.withUnsafeBytes {
                    handshake_client_request_display_cache(
                        client, terminalID, code, key, sourceOffset,
                        $0.bindMemory(to: UInt8.self).baseAddress, bytes.count, &pending)
                }
            }
            if status == HANDSHAKE_STATUS_EMPTY {
                try await Task.sleep(for: .milliseconds(10))
            } else {
                try check(status)
            }
        }
        defer { _ = handshake_display_cache_request_destroy(pending) }
        while true {
            try Task.checkCancellation()
            var response = HandshakeBuffer()
            let status = handshake_display_cache_request_poll(pending, &response)
            if status == HANDSHAKE_STATUS_EMPTY {
                try await Task.sleep(for: .milliseconds(10))
                continue
            }
            try check(status)
            let data = try consume(&response)
            guard let flag = data.first, flag <= 1 else { throw CoreFailure.unexpectedCommandResult }
            return flag == 1 ? Data(data.dropFirst()) : nil
        }
    }
}
