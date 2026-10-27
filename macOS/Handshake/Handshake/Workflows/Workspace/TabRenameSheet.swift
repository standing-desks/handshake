import SwiftUI

struct TabRenameSheet: View {
    let workflow: CoreWorkflow
    let save: (String) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var failure: String?
    @State private var saving = false
    @FocusState private var isFocused: Bool

    init(workflow: CoreWorkflow, save: @escaping (String) async throws -> Void) {
        self.workflow = workflow
        self.save = save
        _name = State(initialValue: workflow.customName ?? workflow.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Tab").font(.headline)
            TextField("Tab name", text: $name).textFieldStyle(.roundedBorder).focused($isFocused)
                .accessibilityIdentifier("tabName")
            if let failure { Text(failure).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button("Rename") { saving = true }.keyboardShortcut(.defaultAction)
                    .disabled(
                        saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 200)
            }
        }
        .padding(24).frame(width: 380).onAppear { isFocused = true }
        .interactiveDismissDisabled(saving)
        .task(id: saving) {
            guard saving else { return }
            do {
                try await save(name)
                dismiss()
            } catch {
                failure = error.localizedDescription
                saving = false
            }
        }
    }
}
