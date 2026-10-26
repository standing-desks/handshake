import AppKit
import SwiftUI

struct SharedMemorySheet: View {
    @Environment(CoreClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: SharedMemoryModel
    let folder: String
    let source: CoreMemorySource?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Shared Memory").font(.title2.bold())
                    Text("Codex + Claude Code · \(URL(filePath: folder).lastPathComponent)")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            policy
            if model.snapshot?.deliveryReady == false {
                Text(
                    model.snapshot?.enabled == true
                        ? "The catalog is unavailable. Repair it or disable sharing before starting an agent."
                        : "Sharing is disabled, but removing the previously published files is incomplete."
                )
                .font(.caption).foregroundStyle(.orange)
            }
            if let failure = model.failure {
                Text(failure).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            HSplitView {
                noteList.frame(minWidth: 180, idealWidth: 230, maxWidth: 280)
                noteDetail.frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
            }.frame(minHeight: 240)
            composer
            footer
        }
        .padding(24).frame(width: 780, height: 700)
        .task(id: model.selectedID) {
            await model.loadSelected(client: client, folder: folder)
        }
    }

    private var policy: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(
                "Automatically share memories in this folder",
                isOn: Binding(
                    get: { model.snapshot?.enabled ?? false },
                    set: { perform(.init(operation: "setEnabled", enabled: $0)) }
                )
            ).disabled(model.isWorking || model.snapshot == nil)
                .accessibilityIdentifier("sharedMemoryPolicy")
            Text(
                "New notes in this folder's shared inbox are available to both harnesses. "
                    + "Start a new agent after enabling. Running agents can re-read the catalog."
            ).font(.caption).foregroundStyle(.secondary)
            Text("Shared notes may be sent to the model provider used by either harness.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(12).background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
    }

    private var noteList: some View {
        VStack(spacing: 8) {
            TextField("Find memories", text: $model.query)
                .textFieldStyle(.roundedBorder).accessibilityIdentifier("findSharedMemory")
            List(selection: $model.selectedID) {
                ForEach(model.filteredNotes) { note in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(note.title).lineLimit(2)
                        Text(note.status.capitalized).font(.caption).foregroundStyle(.secondary)
                    }.tag(note.id)
                }
            }.overlay {
                if model.filteredNotes.isEmpty {
                    ContentUnavailableView(
                        model.query.isEmpty ? "No shared memories" : "No matching memories",
                        systemImage: "brain",
                        description: Text(model.query.isEmpty ? "Add a note below." : "Try another title or source."))
                }
            }
        }
    }

    private var noteDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let note = model.selected {
                    Text(note.title).font(.headline)
                    if let text = model.selectedText {
                        Text(text).font(.body).textSelection(.enabled)
                            .accessibilityIdentifier("sharedMemoryContent")
                    } else if model.isLoadingSelected {
                        ProgressView("Loading memory…")
                    } else {
                        if let error = model.selectedDetailError {
                            Text(error).font(.caption).foregroundStyle(.red)
                        }
                        Button("Retry loading memory") {
                            Task { await model.loadSelected(client: client, folder: folder) }
                        }.disabled(model.isWorking)
                    }
                    Divider()
                    Text("Source: \(note.source)").font(.caption).foregroundStyle(.secondary)
                    Text("SHA-256: \(note.digest)").font(.caption2.monospaced()).textSelection(.enabled)
                    if note.status == "held" {
                        Text(
                            "The original file changed. This note is held; withdraw it and add a reviewed replacement."
                        )
                        .font(.caption).foregroundStyle(.orange)
                    }
                    if note.status != "withdrawn" {
                        Button("Withdraw from shared memory", role: .destructive) {
                            perform(.init(operation: "withdraw", id: note.id))
                        }.disabled(model.isWorking)
                    }
                } else {
                    Text("Select a memory to inspect its content and source.").foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add a durable procedure or correction for this folder").font(.subheadline)
            TextEditor(text: $model.draft).font(.body).frame(height: 78)
                .border(.quaternary).accessibilityIdentifier("sharedMemoryDraft")
            HStack {
                Text("Share folder-specific knowledge. Keep secrets and personal memory out.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Share note") { perform(.init(operation: "add", text: model.draft)) }
                    .disabled(model.isWorking || model.snapshot?.enabled != true || model.draft.isEmpty)
                    .accessibilityIdentifier("shareMemoryNote")
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(model.sharedCount) shared · Refreshed every 5 seconds").font(.caption)
                Spacer()
                if let snapshot = model.snapshot {
                    Button("Show files") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: snapshot.catalogPath)])
                    }
                }
                if let source, canImportSelectedSource {
                    Button("Import selected memory snapshot") {
                        perform(.init(operation: "import", sourceID: source.id))
                    }.disabled(model.isWorking || model.snapshot?.enabled != true)
                }
                Button("Refresh") { perform(.init(operation: "refresh")) }.disabled(model.isWorking)
            }
            if let diagnostics = model.snapshot?.diagnostics, !diagnostics.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                            Text(diagnostic).font(.caption).foregroundStyle(.orange)
                        }
                    }
                }.frame(maxHeight: 54)
            }
            Text("Withdrawal stops future delivery. History and already-loaded agent contexts may retain the content.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var canImportSelectedSource: Bool {
        guard let source else { return false }
        return source.scope == .folder
            && (source.harness == .codex || source.harness == .claudeCode)
            && (source.kind == .durable || source.kind == .agentMemory)
    }

    private func perform(_ action: SharedMemoryAction) {
        Task { await model.perform(action, client: client, folder: folder) }
    }
}
