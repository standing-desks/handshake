import Foundation

extension CoreClient {
    func nextTerminalChunk(for terminalID: UInt64) async throws -> CoreTerminalChunk? {
        try Task.checkCancellation()
        guard runState == .running else { throw CoreFailure.notRunning }
        if let chunk = terminalChunkRouter.dequeue(for: terminalID) {
            return chunk
        }
        guard terminalChunkRouter.hasCapacity, !isFetchingTerminalChunk else { return nil }
        isFetchingTerminalChunk = true
        defer { isFetchingTerminalChunk = false }
        guard let chunk = try await transport.nextTerminalChunk() else { return nil }
        guard runState == .running, !isStopping else { throw CoreFailure.notRunning }
        terminalChunkRouter.enqueue(chunk)
        try Task.checkCancellation()
        return terminalChunkRouter.dequeue(for: terminalID)
    }

    /// Drain independently of terminal view lifetime; missing live bytes replay from transcripts.
    func drainTerminalOutput() async throws {
        guard !isFetchingTerminalChunk else { return }
        isFetchingTerminalChunk = true
        defer { isFetchingTerminalChunk = false }
        for _ in 0..<32 {
            guard let chunk = try await transport.nextTerminalChunk() else { break }
            guard runState == .running, !isStopping, !Task.isCancelled else { return }
            terminalChunkRouter.enqueue(chunk)
        }
    }

    func runTerminalOutputPump() async {
        while !Task.isCancelled && !isStopping {
            do {
                try await drainTerminalOutput()
                try await Task.sleep(for: .milliseconds(10))
            } catch is CancellationError { return } catch {
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

}
