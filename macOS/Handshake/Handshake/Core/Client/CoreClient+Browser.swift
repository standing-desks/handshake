import Foundation

extension CoreClient {
    func browserControl(_ command: BrowserHostCommand) async throws -> BrowserControlState {
        guard runState == .running, !isStopping else { throw CoreFailure.notRunning }
        let data = try JSONEncoder().encode(command)
        let result = try await transport.browserControl(data)
        return try JSONDecoder().decode(BrowserControlState.self, from: result)
    }
}
