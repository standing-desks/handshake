import SwiftUI

/// The entire label rectangle is clickable, including the space around each symbol.
struct WorkflowGraphZoomControls: View {
    @Binding var zoom: Double
    let fitGraph: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            zoomButton(increasing: false).disabled(zoom <= 0.25)
            Button {
                zoom = 1
            } label: {
                Text(zoom, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit().frame(minWidth: 40, minHeight: 28).contentShape(.rect)
            }.help("Actual size").accessibilityLabel("Actual size")
                .accessibilityValue(zoom.formatted(.percent.precision(.fractionLength(0))))
                .accessibilityIdentifier("designerZoomReset")
            zoomButton(increasing: true).disabled(zoom >= 2)
            Divider().frame(height: 14)
            Button(action: fitGraph) {
                Text("Fit").frame(minWidth: 36, minHeight: 28).contentShape(.rect)
            }.help("Fit the graph to this canvas")
        }.buttonStyle(.borderless).controlSize(.small)
    }

    private func zoomButton(increasing: Bool) -> some View {
        let title = increasing ? "Zoom in" : "Zoom out"
        return Button {
            zoom = increasing ? min(2, zoom + 0.1) : max(0.25, zoom - 0.1)
        } label: {
            Label(title, systemImage: increasing ? "plus" : "minus").labelStyle(.iconOnly)
                .frame(width: 28, height: 28).contentShape(.rect)
        }.help(title).accessibilityIdentifier(increasing ? "designerZoomIn" : "designerZoomOut")
    }
}
