import Foundation
import Observation

@Observable
final class NativeMemoryImportModel {
    private(set) var snapshot: NativeMemoryImportSnapshot?
    private(set) var isWorking = false
    private(set) var failure: String?
    private var lastAction: NativeMemoryImportAction?

    var canImport: Bool { snapshot?.canImport == true && !isWorking && failure == nil }
    var primaryActionTitle: String { isRemovingImports ? "Remove imported memories" : "Import to Codex" }
    private var isRemovingImports: Bool { snapshot?.sourceCount == 0 && snapshot?.canImport == true }

    var statusTitle: String {
        if isWorking {
            return switch lastAction {
            case .removeImported: "Removing imported memories…"
            case .importMemories: "Importing memories…"
            default: "Checking memories…"
            }
        }
        if failure != nil {
            return switch lastAction {
            case .removeImported: "Removal failed"
            case .importMemories: "Import failed"
            default: "Couldn’t check memories"
            }
        }
        return switch snapshot?.status {
        case "ready": isRemovingImports ? "Ready to remove imported memories" : "Ready to import"
        case "imported": "Submitted to Codex"
        case "current": "No pending import"
        case "unconfirmed": lastAction == .removeImported ? "Removal not confirmed" : "Import not confirmed"
        case "unavailable": lastAction == .removeImported ? "Removal unavailable" : "Import unavailable"
        default: "Native memory"
        }
    }

    func refresh(client: CoreClient, folder: String) async {
        await perform(.status, client: client, folder: folder)
    }

    func importMemories(client: CoreClient, folder: String) async {
        guard canImport else { return }
        await perform(isRemovingImports ? .removeImported : .importMemories, client: client, folder: folder)
    }

    private func perform(_ action: NativeMemoryImportAction, client: CoreClient, folder: String) async {
        while isWorking {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
        }
        guard !Task.isCancelled else { return }
        lastAction = action
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
