import SwiftUI

struct HandshakeMemorySheet: View {
    @Environment(\.appZoom) private var zoom
    @Environment(\.appZoomMaximumPresentationSize) private var maximumSize
    @State private var parentWidth = CGFloat.infinity
    @Environment(CoreClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: HandshakeMemoryModel
    let folder: String
    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Handshake Memories").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let snapshot = model.snapshot {
                        Toggle(
                            "Automatically share project memories",
                            isOn: Binding(
                                get: { snapshot.enabled },
                                set: { enabled in perform(.setEnabled(enabled)) }
                            )
                        )
                        .disabled(model.isUpdating)
                        .accessibilityIdentifier("handshakeMemoryEnabled")
                        VStack(alignment: .leading, spacing: 6) {
                            Label(
                                status(snapshot),
                                systemImage: snapshot.status == "held" ? "pause.circle" : "arrow.triangle.2.circlepath"
                            )
                            .font(.headline).accessibilityIdentifier("handshakeMemoryStatus")
                            Text(snapshot.message).font(.callout).foregroundStyle(.secondary)
                        }
                        Text("\(snapshot.records.count) project memories").font(.subheadline.bold())
                            .accessibilityIdentifier("handshakeMemoryCount")
                        if snapshot.records.isEmpty {
                            Text(
                                """
                                Memories saved by Claude or Codex appear here automatically.
                                Start a fresh agent session in Handshake to use this project’s native memory profile.
                                """
                            )
                            .foregroundStyle(.secondary)
                        }
                        ForEach(snapshot.records) { record in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(record.title).font(.headline)
                                Text(record.preview).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            Button {
                                showsDetails.toggle()
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: showsDetails ? "chevron.down" : "chevron.right")
                                        .font(.caption.weight(.semibold)).accessibilityHidden(true)
                                    Text("Storage and native profiles")
                                    Spacer(minLength: 0)
                                }.frame(maxWidth: .infinity, minHeight: 24, alignment: .leading).contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("handshakeMemoryDetails")
                            .accessibilityValue(showsDetails ? "Expanded" : "Collapsed")
                            if showsDetails {
                                path("Handshake · AMIS 0.4", snapshot.amisPath)
                                path("Claude native memory", snapshot.claudePath)
                                path("Codex native home", snapshot.codexPath)
                                Text(
                                    """
                                    Local consolidation makes no model calls.
                                    Codex generates its startup summary when its background memory pass and quota allow.
                                    Existing Codex sessions keep their original native home.
                                    Start a fresh Handshake session for shared memories.
                                    """
                                )
                                .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } else if model.failure == nil {
                        ProgressView("Checking project memories…")
                    }
                    if let failure = model.failure {
                        Text(failure).foregroundStyle(.red).textSelection(.enabled)
                            .accessibilityIdentifier("handshakeMemoryFailure")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            }.frame(idealHeight: 320, maxHeight: 440)
                .accessibilityIdentifier("handshakeMemoryViewport")
            Divider()
            HStack {
                Text("Claude ↔ Handshake ↔ Codex").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Sync now") { perform(.sync) }.disabled(model.isUpdating)
                    .accessibilityIdentifier("handshakeMemorySync")
            }.padding(16)
        }
        .frame(width: min(500, maximumSize.width, parentWidth / (zoom?.scale ?? 1)))
        .frame(maxHeight: maximumSize.height)
        .background { NativeMemoryPresentationBounds { parentWidth = $0 }.frame(width: 0, height: 0) }
        .task(id: folder) { await model.watch(client: client, folder: folder) }
    }

    private func perform(_ action: HandshakeMemoryAction) {
        Task { await model.perform(client: client, folder: folder, action: action) }
    }

    private func path(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.bold())
            Text(value).font(.caption.monospaced()).textSelection(.enabled)
                .accessibilityIdentifier("handshakeMemoryPath-\(title)")
        }
    }

    private func status(_ snapshot: HandshakeMemorySnapshot) -> String {
        switch snapshot.status {
        case "sharing": "Sharing automatically"
        case "paused": "Sharing paused"
        case "held": "Waiting to reconcile"
        default: "Starting automatic sharing"
        }
    }
}
