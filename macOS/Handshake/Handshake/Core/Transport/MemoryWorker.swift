import Foundation
import HandshakeCore

/// Memory scans run independently so snapshots never hold up terminal I/O.
actor MemoryWorker {
    func memorySave(_ request: CoreMemorySaveRequest) throws -> FileSaveResult {
        try Task.checkCancellation()
        let data = try JSONEncoder().encode(request)
        var response = HandshakeBuffer()
        let status = data.withUnsafeBytes { bytes in
            handshake_memory_save(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &response)
        }
        try checkMemoryStatus(status)
        return try JSONDecoder().decode(FileSaveResult.self, from: consumeMemory(&response))
    }

    func memoryCatalog(_ request: CoreMemoryRequest) throws -> CoreMemoryCatalog {
        try Task.checkCancellation()
        let data = try JSONEncoder().encode(request)
        var response = HandshakeBuffer()
        let status = data.withUnsafeBytes { bytes in
            handshake_memory_catalog(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &response)
        }
        try checkMemoryStatus(status)
        return try JSONDecoder().decode(CoreMemoryCatalog.self, from: consumeMemory(&response))
    }

    func memoryRead(_ request: CoreMemoryRequest) throws -> CoreMemoryRead {
        try Task.checkCancellation()
        let data = try JSONEncoder().encode(request)
        var response = HandshakeBuffer()
        let status = data.withUnsafeBytes { bytes in
            handshake_memory_read(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &response)
        }
        try checkMemoryStatus(status)
        return try JSONDecoder().decode(CoreMemoryRead.self, from: consumeMemory(&response))
    }

    private func consumeMemory(_ buffer: inout HandshakeBuffer) throws -> Data {
        defer { _ = handshake_buffer_release(&buffer) }
        guard let bytes = buffer.data else { throw CoreFailure.empty }
        return Data(bytes: bytes, count: buffer.length)
    }

    private func checkMemoryStatus(_ status: HandshakeStatus) throws {
        switch status {
        case HANDSHAKE_STATUS_OK: return
        case HANDSHAKE_STATUS_NULL_POINTER: throw CoreFailure.nullPointer
        case HANDSHAKE_STATUS_INVALID_UTF8: throw CoreFailure.invalidUTF8
        case HANDSHAKE_STATUS_MALFORMED_COMMAND: throw CoreFailure.malformedCommand
        case HANDSHAKE_STATUS_INVALID_ARGUMENT: throw CoreFailure.invalidArgument
        case HANDSHAKE_STATUS_PANIC: throw CoreFailure.panic
        default: throw CoreFailure.failed("The local memory source couldn't be read. Refresh and try again.")
        }
    }
}
