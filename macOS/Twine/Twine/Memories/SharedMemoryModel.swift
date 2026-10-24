import Foundation
import Observation

@Observable
final class SharedMemoryModel {
    private(set) var snapshot: SharedMemorySnapshot?
    private(set) var isWorking = false
    private(set) var failure: String?
    var selectedID: String?
    var draft = ""

    var selected: SharedMemoryNote? { snapshot?.notes.first { $0.id == selectedID } }
    var sharedCount: Int { snapshot?.notes.filter { $0.status == "shared" }.count ?? 0 }

    func perform(_ action: SharedMemoryAction, client: CoreClient, folder: String, background: Bool = false) async {
        while isWorking {
            guard !background else { return }
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let snapshot = try await client.sharedMemory(folder: folder, action: action)
            try Task.checkCancellation()
            self.snapshot = snapshot
            if !background { failure = nil }
            if action.operation == "add", draft == action.text { draft = "" }
            if !snapshot.notes.contains(where: { $0.id == selectedID }) {
                selectedID = snapshot.notes.first?.id
            }
        } catch is CancellationError {
            return
        } catch {
            if !background || failure == nil { failure = error.localizedDescription }
        }
    }
}
