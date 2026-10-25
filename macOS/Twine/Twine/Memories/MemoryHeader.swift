import SwiftUI

struct MemoryHeader: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var model: MemoryModel
    var openNativeMemory: (() -> Void)?

    var body: some View {
        HStack {
            Button {
                withAnimation(reduceMotion ? nil : Motion.sectionToggle) { model.isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).frame(width: 10)
                        .rotationEffect(.degrees(model.isExpanded ? 90 : 0))
                    Text("Memories").sidebarSectionLabelStyle()
                    Spacer(minLength: 0)
                }
                .frame(height: SidebarLayout.sectionHeaderHeight)
                .contentShape(.rect)
            }.buttonStyle(.plain).accessibilityIdentifier("memoryEntry-outline")
                .accessibilityValue(model.isExpanded ? "Expanded" : "Collapsed")
                .help(model.isExpanded ? "Collapse Memories" : "Open Memories")
            if let openNativeMemory {
                Button(action: openNativeMemory) {
                    Text("Twine")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 4)
                        .frame(height: 26).contentShape(.rect)
                }
                .buttonStyle(.plain).accessibilityIdentifier("openNativeMemory")
                .accessibilityLabel("Twine Memories")
                .help("Automatic native memory sharing")
            }
            if model.isExpanded {
                Button(action: model.refresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain).help("Rescan local memory sources")
                .accessibilityLabel("Refresh memories")
                .accessibilityIdentifier("refreshMemories")
            }
        }
        .frame(height: SidebarLayout.sectionHeaderHeight)
        .padding(.horizontal, SidebarLayout.sectionHeaderPadding)
    }
}

#Preview { MemoryViewPreview() }
