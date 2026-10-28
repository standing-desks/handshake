import AppKit
import SwiftUI

/// The project policy and its settings stay beside the Memories disclosure, even when collapsed.
struct MemorySharingControls: View {
    @Environment(CoreClient.self) private var client
    @Bindable var model: HandshakeMemoryModel
    let folder: String
    let refreshSources: () -> Void
    @State private var showsSettings = false
    @State private var correction: HandshakeMemorySummary?
    @State private var ownerWindowNumber: Int?

    var body: some View {
        HStack(spacing: 6) {
            Toggle(
                "Share",
                isOn: Binding(
                    get: { model.snapshot?.enabled ?? false },
                    set: { enabled in
                        ownerWindowNumber = NSApp.keyWindow?.windowNumber
                        Task {
                            await model.perform(client: client, folder: folder, action: .setEnabled(enabled))
                            if model.failure != nil { showsSettings = true }
                        }
                    }
                )
            )
            .toggleStyle(.switch).controlSize(.mini).font(.system(size: 11))
            .fixedSize()
            .disabled(model.snapshot == nil || model.isUpdating)
            .accessibilityLabel("Share project memories")
            .accessibilityHint("Automatically share this project’s memories between supported agents.")
            .accessibilityIdentifier("handshakeMemoryEnabled")
            .help("Automatically share project memories between supported agents")
            Divider().frame(height: 16)
            Button {
                ownerWindowNumber = NSApp.keyWindow?.windowNumber
                showsSettings.toggle()
            } label: {
                Image(systemName: "gearshape").font(.system(size: 12))
                    .frame(width: 24, height: 26).contentShape(.rect)
            }
            .buttonStyle(.plain).accessibilityLabel("Memory settings")
            .help("Memory settings").accessibilityIdentifier("openNativeMemory")
            .popover(isPresented: $showsSettings, arrowEdge: .trailing) {
                MemorySharingSettings(model: model, folder: folder, refreshSources: refreshSources) { record in
                    showsSettings = false
                    correction = record
                }
                .background {
                    MemorySharingPopoverDismissal(ownerWindowNumber: ownerWindowNumber) { showsSettings = false }
                        .frame(width: 0, height: 0)
                }
                .appZoom()
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 6))
        .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary, lineWidth: 0.5) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Project memory sharing")
        .sheet(item: $correction) { record in
            MemoryCorrectionSheet(model: model, folder: folder, record: record).appZoom()
        }
        .onChange(of: folder) {
            showsSettings = false
            correction = nil
        }
    }
}
