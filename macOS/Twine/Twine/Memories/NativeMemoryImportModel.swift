import Foundation
import Observation

@Observable
final class NativeMemoryImportModel {
    private(set) var snapshot: NativeMemoryImportSnapshot?
    private(set) var isWorking = false
    private(set) var failure: String?

    var canImport: Bool { snapshot?.canImport == true && !isWorking && failure == nil }

    var statusTitle: String {
        switch snapshot?.status {
        case "ready": "Ready to import"
        case "imported": "Submitted to Codex"
        case "current": "No pending import"
        case "unconfirmed": "Import not confirmed"
        case "unavailable": "Import unavailable"
        default: "Native memory"
        }
    }

    func refresh(client: CoreClient, folder: String) async {
        await perform(.status, client: client, folder: folder)
    }

    func importMemories(client: CoreClient, folder: String) async {
        guard canImport else { return }
        await perform(.importMemories, client: client, folder: folder)
    }

    private func perform(_ action: NativeMemoryImportAction, client: CoreClient, folder: String) async {
        while isWorking {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
        }
        guard !Task.isCancelled else { return }
        isWorking = true
        failure = nil
        defer { isWorking = false }
        do {
            let snapshot = try await client.nativeMemoryImport(.init(folder: folder, action: action))
            try Task.checkCancellation()
            self.snapshot = snapshot
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            failure = error.localizedDescription
        }
    }
}
