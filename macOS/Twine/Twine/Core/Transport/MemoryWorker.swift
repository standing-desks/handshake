import Foundation
import TwineCore

/// Memory scans run independently so snapshots never hold up terminal I/O.
actor MemoryWorker {
    func twineMemories(_ request: TwineMemoryRequest) throws -> TwineMemorySnapshot {
        try Task.checkCancellation()
        let data = try JSONEncoder().encode(request)
        var response = TwineBuffer()
        let status = data.withUnsafeBytes { bytes in
            twine_twine_memories(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &response)
        }
        try checkMemoryStatus(status)
        let result = try JSONDecoder().decode(TwineMemoryResponse.self, from: consumeMemory(&response))
        if let error = result.error { throw CoreFailure.failed(error) }
        guard let snapshot = result.snapshot else { throw CoreFailure.empty }
        return snapshot
    }

    func nativeMemoryImport(_ request: NativeMemoryImportRequest) throws -> NativeMemoryImportSnapshot {
        try Task.checkCancellation()
        let data = try JSONEncoder().encode(request)
        var response = TwineBuffer()
        let status = data.withUnsafeBytes { bytes in
            twine_native_memory_import(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &response)
        }
        try checkMemoryStatus(status)
        let result = try JSONDecoder().decode(NativeMemoryImportResponse.self, from: consumeMemory(&response))
        if let error = result.error { throw CoreFailure.failed(error) }
        guard let snapshot = result.snapshot else { throw CoreFailure.empty }
        return snapshot
    }

    func sharedMemory(_ request: SharedMemoryRequest) throws -> SharedMemorySnapshot {
        try Task.checkCancellation()
        let data = try JSONEncoder().encode(request)
        var response = TwineBuffer()
        let status = data.withUnsafeBytes { bytes in
            twine_shared_memory(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &response)
        }
        try checkMemoryStatus(status)
        let result = try JSONDecoder().decode(SharedMemoryResponse.self, from: consumeMemory(&response))
        if let error = result.error { throw CoreFailure.failed(error) }
        guard let snapshot = result.snapshot else { throw CoreFailure.empty }
        return snapshot
    }

    func memorySave(_ request: CoreMemorySaveRequest) throws -> FileSaveResult {
        try Task.checkCancellation()
        let data = try JSONEncoder().encode(request)
        var response = TwineBuffer()
        let status = data.withUnsafeBytes { bytes in
            twine_memory_save(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &response)
        }
        try checkMemoryStatus(status)
        return try JSONDecoder().decode(FileSaveResult.self, from: consumeMemory(&response))
    }

    func memoryCatalog(_ request: CoreMemoryRequest) throws -> CoreMemoryCatalog {
        try Task.checkCancellation()
        let data = try JSONEncoder().encode(request)
        var response = TwineBuffer()
        let status = data.withUnsafeBytes { bytes in
            twine_memory_catalog(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &response)
        }
        try checkMemoryStatus(status)
        return try JSONDecoder().decode(CoreMemoryCatalog.self, from: consumeMemory(&response))
    }

    func memoryRead(_ request: CoreMemoryRequest) throws -> CoreMemoryRead {
        try Task.checkCancellation()
        let data = try JSONEncoder().encode(request)
        var response = TwineBuffer()
        let status = data.withUnsafeBytes { bytes in
            twine_memory_read(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &response)
        }
        try checkMemoryStatus(status)
        return try JSONDecoder().decode(CoreMemoryRead.self, from: consumeMemory(&response))
    }

    private func consumeMemory(_ buffer: inout TwineBuffer) throws -> Data {
        defer { _ = twine_buffer_release(&buffer) }
        guard let bytes = buffer.data else { throw CoreFailure.empty }
        return Data(bytes: bytes, count: buffer.length)
    }

    private func checkMemoryStatus(_ status: TwineStatus) throws {
        switch status {
        case TWINE_STATUS_OK: return
        case TWINE_STATUS_NULL_POINTER: throw CoreFailure.nullPointer
        case TWINE_STATUS_INVALID_UTF8: throw CoreFailure.invalidUTF8
        case TWINE_STATUS_MALFORMED_COMMAND: throw CoreFailure.malformedCommand
        case TWINE_STATUS_INVALID_ARGUMENT: throw CoreFailure.invalidArgument
        case TWINE_STATUS_PANIC: throw CoreFailure.panic
        default: throw CoreFailure.failed("The local memory source couldn't be read. Refresh and try again.")
        }
    }
}
