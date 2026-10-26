import Foundation
import Observation

@Observable
final class SharedMemoryModel {
    private(set) var snapshot: SharedMemorySnapshot?
    private(set) var isWorking = false
    private(set) var failure: String?
    private var detail: SharedMemoryDetail?
    private var detailError: String?
    private var detailErrorID: String?
    private var loadingID: String?
    var selectedID: String?
    var draft = ""
    var query = "" {
        didSet { reconcileSelection() }
    }

    var selected: SharedMemoryNote? { snapshot?.notes.first { $0.id == selectedID } }
    var sharedCount: Int { snapshot?.notes.filter { $0.status == "shared" }.count ?? 0 }
    var filteredNotes: [SharedMemoryNote] {
        let notes = snapshot?.notes ?? []
        guard !query.isEmpty else { return notes }
        return notes.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.source.localizedCaseInsensitiveContains(query)
        }
    }
    var selectedText: String? {
        guard let selected, detail?.id == selected.id, detail?.digest == selected.digest else { return nil }
        return detail?.text
    }
    var selectedDetailError: String? { detailErrorID == selectedID ? detailError : nil }
    var isLoadingSelected: Bool { selectedID != nil && loadingID == selectedID }

    func loadSelected(client: CoreClient, folder: String) async {
        guard let id = selectedID, selectedText == nil else { return }
        loadingID = id
        detailErrorID = id
        detailError = nil
        defer { if loadingID == id { loadingID = nil } }
        await perform(.init(operation: "read", id: id), client: client, folder: folder)
    }

    private func reconcileSelection() {
        if !filteredNotes.contains(where: { $0.id == selectedID }) {
            selectedID = filteredNotes.first?.id
        }
    }

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
            accept(snapshot, action: action, background: background)
        } catch is CancellationError {
            return
        } catch {
            if action.operation == "read" {
                detailErrorID = action.id
                detailError = error.localizedDescription
            } else if !background || failure == nil {
                failure = error.localizedDescription
            }
        }
    }

    private func accept(_ snapshot: SharedMemorySnapshot, action: SharedMemoryAction, background: Bool) {
        self.snapshot = snapshot
        if !background, action.operation != "read" { failure = nil }
        if action.operation == "add", draft == action.text { draft = "" }
        reconcileSelection()
        if let received = snapshot.detail, received.id == selectedID {
            detail = received
        }
        if detail?.id != selected?.id || detail?.digest != selected?.digest {
            detail = nil
        }
    }
}
