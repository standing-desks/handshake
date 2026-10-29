import SwiftUI

/// The entire disclosure header is a native button, including its label and empty space.
struct WorkflowDisclosureStyle: DisclosureGroupStyle {
    @Environment(\.effectiveReduceMotion) private var reduceMotion
    let identifier: String

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(reduceMotion ? nil : Motion.disclosure) { configuration.isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                    configuration.label
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, minHeight: 28, alignment: .leading).contentShape(.rect)
            }.buttonStyle(.plain)
                .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
                .accessibilityIdentifier(identifier)
            if configuration.isExpanded { configuration.content }
        }
    }
}
