import Foundation

extension CoreClient {
    func handshakeMemories(folder: String, action: HandshakeMemoryAction) async throws -> HandshakeMemorySnapshot {
        try await transport.handshakeMemories(folder: folder, action: action)
    }

    func nativeMemoryImport(_ request: NativeMemoryImportRequest) async throws -> NativeMemoryImportSnapshot {
        try await transport.nativeMemoryImport(request)
    }

    func sharedMemory(folder: String, action: SharedMemoryAction) async throws -> SharedMemorySnapshot {
        try await transport.sharedMemory(folder: folder, action: action)
    }

    func memoryCatalog(_ request: CoreMemoryRequest) async throws -> CoreMemoryCatalog {
        try await transport.memoryCatalog(request)
    }

    func memoryRead(_ request: CoreMemoryRequest) async throws -> CoreMemoryRead {
        try await transport.memoryRead(request)
    }

    func memorySave(_ request: CoreMemorySaveRequest) async throws -> FileSaveResult {
        try await transport.memorySave(request)
    }
}
