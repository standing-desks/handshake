import SwiftUI

struct NativeMemoryImportSheet: View {
    @Environment(CoreClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: NativeMemoryImportModel
    let folder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Native Memory").font(.title2.bold())
                    Text(URL(filePath: folder).lastPathComponent)
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Import this folder's Claude Code memories into Codex's native memory system.")
                        .font(.callout)
                    if let snapshot = model.snapshot {
                        VStack(alignment: .leading, spacing: 16) {
                            location("Claude Code", path: snapshot.claudePath)
                            Text("\(snapshot.sourceCount) native memory files")
                                .font(.caption).foregroundStyle(.secondary)
                                .accessibilityIdentifier("nativeMemorySourceCount")
                            Divider()
                            location("Codex", path: snapshot.codexPath)
                        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(model.statusTitle).font(.headline)
                                .accessibilityIdentifier("nativeMemoryImportStatus")
                            Text(snapshot.message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                                .accessibilityIdentifier("nativeMemoryImportMessage")
                        }
                    } else if model.isWorking {
                        ProgressView("Checking native memory…")
                    }
                    if let failure = model.failure {
                        Text(failure).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                            .accessibilityIdentifier("nativeMemoryImportFailure")
                    }
                }
            }
            HStack {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await model.refresh(client: client, folder: folder) }
                }.disabled(model.isWorking)
                Spacer()
                if model.isWorking { ProgressView().controlSize(.small) }
                Button("Import Claude Memories") {
                    Task { await model.importMemories(client: client, folder: folder) }
                }
                .disabled(!model.canImport)
                .accessibilityIdentifier("importClaudeMemories")
            }
        }
        .padding(24).frame(width: 680, height: 460)
        .task(id: folder) { await model.refresh(client: client, folder: folder) }
    }

    private func location(_ title: String, path: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(path).font(.caption.monospaced()).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("nativeMemoryPath-\(title)")
        }
    }
}
