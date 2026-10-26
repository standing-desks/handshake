import Foundation
import Observation

@Observable
final class HandshakeMemoryModel {
    private(set) var snapshot: HandshakeMemorySnapshot?
    private(set) var failure: String?
    private(set) var isUpdating = false
    @ObservationIgnored private var failureIsAction = false
    @ObservationIgnored private var generation = UUID()

    func watch(client: CoreClient, folder: String) async {
        let token = UUID()
        generation = token
        snapshot = nil
        failure = nil
        failureIsAction = false
        while !Task.isCancelled, generation == token {
            if !isUpdating {
                isUpdating = true
                await update(client: client, folder: folder, action: .status, token: token)
                isUpdating = false
            }
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
        }
    }

    func perform(client: CoreClient, folder: String, action: HandshakeMemoryAction) async {
        guard !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }
        await update(client: client, folder: folder, action: action, token: generation)
    }

    private func update(client: CoreClient, folder: String, action: HandshakeMemoryAction, token: UUID) async {
        do {
            let snapshot = try await client.handshakeMemories(folder: folder, action: action)
            guard !Task.isCancelled, generation == token else { return }
            self.snapshot = snapshot
            if action != .status || !failureIsAction {
                failure = nil
                failureIsAction = false
            }
        } catch {
            guard !Task.isCancelled, generation == token else { return }
            if action != .status || !failureIsAction {
                failure = error.localizedDescription
                failureIsAction = action != .status
            }
        }
    }
}
