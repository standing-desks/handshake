import SwiftUI

/// Secondary information belongs in a transient native popover, with one policy toggle in the header.
struct MemorySharingSettings: View {
    @Environment(\.appZoomMaximumPresentationSize) private var maximumSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(CoreClient.self) private var client
    @Bindable var model: HandshakeMemoryModel
    let folder: String
    let refreshSources: () -> Void
    var correct: (HandshakeMemorySummary) -> Void = { _ in }
    @State private var showsMemories = false
    @State private var showsStorage = false
    @State private var showsArchive = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Memory settings").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let failure = model.failure {
                        Text(failure).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                            .accessibilityIdentifier("handshakeMemoryFailure")
                    }
                    if let snapshot = model.snapshot {
                        LabeledContent {
                            Text(MemorySharingProfile.names(snapshot.sharingProfiles))
                                .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("memorySharingAgents")
                        } label: {
                            Text("Agents")
                        }.font(.caption).foregroundStyle(.secondary)
                        Text(snapshot.sharingStatus).font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("handshakeMemoryStatus")
                            .help("Live refresh applies to agents started with this feature enabled.")
                        if snapshot.status == "held" {
                            Text(snapshot.message).font(.caption).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Divider()
                        disclosure(
                            "\(snapshot.records.count) project memories", expanded: $showsMemories,
                            id: "handshakeMemoryCount")
                        if showsMemories {
                            memories(snapshot.records)
                        }
                        if let archived = snapshot.archivedRecords, !archived.isEmpty {
                            disclosure(
                                "Archived memories (\(archived.count))", expanded: $showsArchive,
                                id: "handshakeMemoryArchive")
                            if showsArchive { archive(archived, enabled: snapshot.enabled) }
                        }
                        disclosure(
                            "Storage and native profiles", expanded: $showsStorage, id: "handshakeMemoryDetails")
                        if showsStorage {
                            VStack(alignment: .leading, spacing: 10) {
                                path("AMIS 0.4 library", snapshot.amisPath, id: "amis")
                                ForEach(snapshot.sharingProfiles) { profile in
                                    path(profile.name, profile.path, id: profile.id)
                                }
                                Text(
                                    """
                                    Shared memories refresh at each prompt in agents started with this feature enabled.
                                    Older sessions keep their original memory profile.
                                    Native startup memory generation follows each agent’s schedule and quota.
                                    Local consolidation makes no model calls.
                                    """
                                ).font(.caption).foregroundStyle(.secondary)
                            }.padding(.top, 8)
                        }
                    } else if model.failure == nil {
                        ProgressView("Checking project memories…").controlSize(.small)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: viewportHeight)
            .accessibilityIdentifier("handshakeMemoryViewport")
            Divider()
            HStack {
                Button(model.snapshot == nil ? "Check again" : "Check now") {
                    Task {
                        await model.perform(
                            client: client, folder: folder, action: model.snapshot == nil ? .status : .sync)
                    }
                }
                .disabled(model.isUpdating || model.snapshot?.enabled == false)
                .accessibilityIdentifier("handshakeMemorySync")
                Spacer()
                Button("Refresh sources", action: refreshSources)
                    .accessibilityIdentifier("refreshMemories")
            }.controlSize(.small)
        }
        .padding(16).frame(width: min(330, maximumSize.width))
        .fixedSize(horizontal: false, vertical: true)
    }

    private var viewportHeight: CGFloat {
        let preferred: CGFloat =
            showsStorage || (showsArchive && model.snapshot?.archivedRecords?.isEmpty == false)
            ? 320 : showsMemories ? 220 : (model.snapshot?.archivedRecords?.isEmpty == false ? 166 : 130)
        return min(preferred, max(0, maximumSize.height - 110))
    }

    private func disclosure(_ title: String, expanded: Binding<Bool>, id: String) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : Motion.sectionToggle) { expanded.wrappedValue.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(expanded.wrappedValue ? 90 : 0)).accessibilityHidden(true)
                Text(title)
                Spacer(minLength: 0)
            }.frame(minHeight: 24).contentShape(.rect)
        }
        .buttonStyle(.plain).accessibilityIdentifier(id)
        .accessibilityValue(expanded.wrappedValue ? "Expanded" : "Collapsed")
    }

    @ViewBuilder
    private func memories(_ records: [HandshakeMemorySummary]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if records.isEmpty {
                Text("Memories saved by your agents appear here automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(records) { record in
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.title).font(.caption.bold())
                    if !record.sharingPreview.isEmpty {
                        Text(record.sharingPreview).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
                .contextMenu {
                    Button("Correct memory…") { correct(record) }
                        .disabled(model.isUpdating || model.snapshot?.enabled != true || record.revision == nil)
                    Button("Archive for this project") { perform(.withdraw(record.id)) }
                        .disabled(model.isUpdating)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
    }

    private func archive(_ records: [HandshakeMemorySummary], enabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Kept here for retrieval. No longer shared with your agents.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(records) { record in
                VStack(alignment: .leading, spacing: 6) {
                    Text(record.title).font(.caption.bold())
                    HStack {
                        Button("View") { perform(.readArchive(record.id)) }
                            .accessibilityIdentifier("viewArchivedMemory-\(record.id)")
                        Button("Restore") { perform(.restore(record.id)) }
                            .disabled(!enabled)
                            .help(
                                enabled
                                    ? "Share this memory with your project agents again" : "Enable sharing to restore"
                            )
                            .accessibilityIdentifier("restoreArchivedMemory-\(record.id)")
                    }.controlSize(.small).disabled(model.isUpdating)
                    if let detail = model.archiveDetail, detail.id == record.id {
                        Text(detail.text).font(.caption).textSelection(.enabled)
                            .accessibilityIdentifier("archivedMemoryText")
                    }
                }
            }
        }.padding(.top, 8)
    }

    private func perform(_ action: HandshakeMemoryAction) {
        Task { await model.perform(client: client, folder: folder, action: action) }
    }

    private func path(_ name: String, _ value: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name).font(.caption.bold())
            Text(value).font(.caption.monospaced()).textSelection(.enabled)
                .accessibilityIdentifier("handshakeMemoryPath-\(id)")
        }
    }
}
