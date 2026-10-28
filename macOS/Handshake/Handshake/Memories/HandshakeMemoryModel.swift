import Foundation
import Observation

@Observable
final class HandshakeMemoryModel {
    private(set) var snapshot: HandshakeMemorySnapshot?
    private(set) var archiveDetail: HandshakeMemoryArchiveDetail?
    private(set) var failure: String?
    private(set) var isUpdating = false
    @ObservationIgnored private var failureIsAction = false
    @ObservationIgnored private var generation = UUID()

    func watch(client: CoreClient, folder: String) async {
        let token = UUID()
        generation = token
        snapshot = nil
        archiveDetail = nil
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

    @discardableResult
    func perform(client: CoreClient, folder: String, action: HandshakeMemoryAction) async -> Bool {
        guard !isUpdating else { return false }
        isUpdating = true
        defer { isUpdating = false }
        return await update(client: client, folder: folder, action: action, token: generation)
    }

    @discardableResult
    private func update(client: CoreClient, folder: String, action: HandshakeMemoryAction, token: UUID) async -> Bool {
        do {
            let snapshot = try await client.handshakeMemories(folder: folder, action: action)
            guard !Task.isCancelled, generation == token else { return false }
            self.snapshot = snapshot
            if let detail = snapshot.archiveDetail {
                archiveDetail = detail
            } else if !((snapshot.archivedRecords ?? []).contains { $0.id == archiveDetail?.id }) {
                archiveDetail = nil
            }
            if action != .status || !failureIsAction {
                failure = nil
                failureIsAction = false
            }
            return true
        } catch {
            guard !Task.isCancelled, generation == token else { return false }
            if action != .status || !failureIsAction {
                failure = error.localizedDescription
                failureIsAction = action != .status
            }
            return false
        }
    }
}
