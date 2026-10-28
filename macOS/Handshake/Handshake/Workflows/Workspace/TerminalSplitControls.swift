import SwiftUI

struct TerminalSplitControls: View {
    let split: (TerminalSplit.Direction) -> Void
    let isEnabled: Bool

    var body: some View {
        HStack(spacing: 6) {
            Button {
                split(.right)
            } label: {
                Image(systemName: "rectangle.split.2x1")
                    .frame(width: WorkflowTabLayout.height, height: WorkflowTabLayout.height)
                    .contentShape(.rect)
            }
            .help("Split Right (⌘D)")
            .accessibilityLabel("Split Right")
            .accessibilityIdentifier("splitTerminalRight")
            Button {
                split(.down)
            } label: {
                Image(systemName: "rectangle.split.1x2")
                    .frame(width: WorkflowTabLayout.height, height: WorkflowTabLayout.height)
                    .contentShape(.rect)
            }
            .help("Split Down (⇧⌘D)")
            .accessibilityLabel("Split Down")
            .accessibilityIdentifier("splitTerminalDown")
        }
        .buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
        .disabled(!isEnabled)
        .padding(.horizontal, 4)
    }
}

struct TerminalSplitDivider: View {
    let divider: TerminalSplit.Divider
    let resize: (Double) -> Void

    var body: some View {
        let horizontal = divider.direction == .right
        let length = max(1, (horizontal ? divider.bounds.width : divider.bounds.height) - BentoLayout.gutter)
        let minimum = min(0.5, (horizontal ? 180 : 100) / length)
        PaneDivider(
            axis: horizontal ? .horizontal : .vertical,
            fraction: divider.fraction, sharedLength: length,
            drag: { resize(min(1 - minimum, max(minimum, $0))) },
            save: { resize(min(1 - minimum, max(minimum, $0))) }
        )
        .accessibilityLabel("Resize terminal split")
    }
}

#Preview {
    TerminalSplitControls(split: { _ in NSSound.beep() }, isEnabled: true).padding()
}
