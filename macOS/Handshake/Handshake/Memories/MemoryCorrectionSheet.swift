import SwiftUI

struct MemoryCorrectionSheet: View {
    @Environment(CoreClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: HandshakeMemoryModel
    let folder: String
    let record: HandshakeMemorySummary
    @State private var text = ""
    @State private var failure: String?
    @State private var isSaving = false

    private var replacement: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Correct memory").font(.headline)
            Text(record.title).font(.subheadline.bold())
            Text(record.sharingPreview).font(.caption).foregroundStyle(.secondary).lineLimit(4)
            Text(
                "Write a complete replacement. The old memory and linked summaries will be archived for this project."
            )
            .font(.callout)
            TextEditor(text: $text)
                .font(.body).frame(minHeight: 120)
                .disabled(isSaving)
                .accessibilityLabel("Replacement memory")
                .accessibilityIdentifier("memoryCorrectionText")
            if replacement.utf8.count > 2_000 {
                Text("The correction is too long. Shorten it so agents can receive it in full.")
                    .font(.caption).foregroundStyle(.red)
            }
            if let failure {
                Text(failure).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    .accessibilityIdentifier("memoryCorrectionFailure")
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Spacer()
                Button("Save correction") {
                    guard let revision = record.revision else { return }
                    guard !model.isUpdating else {
                        failure = "Memory is updating. Try again."
                        return
                    }
                    isSaving = true
                    Task {
                        defer { isSaving = false }
                        let saved = await model.perform(
                            client: client, folder: folder,
                            action: .correct(id: record.id, revision: revision, text: replacement))
                        if saved {
                            dismiss()
                        } else {
                            failure = model.failure ?? "Memory is updating. Try again."
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(replacement.isEmpty || replacement.utf8.count > 2_000 || isSaving)
                .accessibilityIdentifier("saveMemoryCorrection")
            }
        }
        .padding(24).frame(width: 440).fixedSize(horizontal: false, vertical: true)
        .interactiveDismissDisabled(isSaving)
    }
}
