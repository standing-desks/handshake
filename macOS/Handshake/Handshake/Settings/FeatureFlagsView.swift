import SwiftUI

struct FeatureFlagsView: View {
    let model: FeatureFlagsModel
    let configurationHasChanges: Bool
    let change: (FeatureFlagID, Bool) -> Void
    let retry: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Choose optional features for all folders.").foregroundStyle(.secondary)
                if let snapshot = model.snapshot {
                    ForEach(snapshot.flags) { flag in
                        Toggle(isOn: Binding(get: { flag.enabled }, set: { change(flag.id, $0) })) {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 8) {
                                    Text(flag.title).font(.headline)
                                    if flag.id == .crossAgentMemoryConsolidation {
                                        Text("Beta").font(.caption.weight(.medium))
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(.quaternary, in: .capsule)
                                            .accessibilityIdentifier("crossAgentMemoryBeta")
                                    }
                                }
                                Text(flag.description).font(.callout).foregroundStyle(.secondary)
                                if flag.id == .crossAgentMemoryConsolidation {
                                    Text("Off by default. Enable to try cross-agent memory sharing.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .toggleStyle(.switch)
                        .accessibilityLabel(
                            flag.id == .crossAgentMemoryConsolidation ? "\(flag.title), Beta" : flag.title
                        )
                        .accessibilityIdentifier("featureFlag-\(flag.id.rawValue)")
                        .disabled(configurationHasChanges || model.isSaving || model.needsApply)
                    }
                    Text("Changes save and apply immediately. Running work stays intact.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if model.failure == nil {
                    ProgressView("Loading feature flags…")
                }
                if configurationHasChanges {
                    Label("Save or discard configuration edits before changing feature flags.", systemImage: "pencil")
                        .font(.callout).foregroundStyle(.secondary)
                        .accessibilityIdentifier("featureFlagsUnsavedConfiguration")
                }
                if model.isSaving { ProgressView("Applying…").controlSize(.small) }
                if let failure = model.failure {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(failure).foregroundStyle(.red).textSelection(.enabled)
                            .accessibilityIdentifier("featureFlagsFailure")
                        Button(model.needsApply ? "Apply Again" : "Reload Flags", action: retry)
                            .accessibilityIdentifier("retryFeatureFlags")
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
        .accessibilityIdentifier("featureFlagsPanel")
    }
}
