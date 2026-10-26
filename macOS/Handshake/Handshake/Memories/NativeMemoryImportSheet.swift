import SwiftUI

struct NativeMemoryImportSheet: View {
    @Environment(CoreClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appZoom) private var zoom
    @Environment(\.appZoomMaximumPresentationSize) private var maximumSize
    @State private var parentWidth = CGFloat.infinity
    @State private var showsLocations = false
    @Bindable var model: NativeMemoryImportModel
    let folder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header.fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .vertical) {
                content.fixedSize(horizontal: false, vertical: true)
                ScrollView { content }.scrollBounceBehavior(.basedOnSize)
                    .accessibilityIdentifier("nativeMemoryDetails")
            }
            footer.fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(width: min(560, maximumSize.width, parentWidth / (zoom?.scale ?? 1)))
        .frame(maxHeight: maximumSize.height)
        .background {
            NativeMemoryPresentationBounds { parentWidth = $0 }.frame(width: 0, height: 0)
        }
        .task(id: folder) { await model.refresh(client: client, folder: folder) }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Import Memories").font(.title2.bold())
                Text(URL(filePath: folder).lastPathComponent)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(folder)
            }
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                Text("Claude Code")
                Image(systemName: "arrow.right").foregroundStyle(.secondary).accessibilityHidden(true)
                Text("Codex")
            }
            .font(.headline)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("From Claude Code to Codex")
            .accessibilityIdentifier("nativeMemoryDirection")
            status
            if let snapshot = model.snapshot {
                Text("\(snapshot.sourceCount) memory files in this folder")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("nativeMemorySourceCount")
                locations(snapshot)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        VStack(spacing: 20) {
            Divider()
            HStack {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await model.refresh(client: client, folder: folder) }
                }
                .disabled(model.isWorking)
                .accessibilityIdentifier("refreshNativeMemory")
                Spacer()
                Button(model.primaryActionTitle) {
                    Task { await model.importMemories(client: client, folder: folder) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canImport)
                .accessibilityIdentifier("importClaudeMemories")
            }
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if model.isWorking { ProgressView().controlSize(.small) }
                Text(model.statusTitle).font(.headline)
                    .accessibilityIdentifier("nativeMemoryImportStatus")
            }
            if let failure = model.failure {
                Text(failure).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    .accessibilityIdentifier("nativeMemoryImportFailure")
            } else if !model.isWorking, let snapshot = model.snapshot {
                Text(snapshot.message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("nativeMemoryImportMessage")
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func locations(_ snapshot: NativeMemoryImportSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                showsLocations.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: showsLocations ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold)).frame(width: 10).accessibilityHidden(true)
                    Text("Memory locations")
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain).font(.callout)
            .accessibilityIdentifier("nativeMemoryLocations")
            .accessibilityValue(showsLocations ? "Expanded" : "Collapsed")
            if showsLocations {
                location("Claude Code", path: snapshot.claudePath)
                location("Codex", path: snapshot.codexPath)
            }
        }
    }

    private func location(_ title: String, path: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.bold())
            Text(path).font(.caption.monospaced()).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("nativeMemoryPath-\(title)")
        }
    }
}
