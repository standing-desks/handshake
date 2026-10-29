import SwiftUI

struct ExperimentalView: View {
    let model: ExperimentalModel
    let configurationHasChanges: Bool
    let change: (ExperimentalFeatureID, Bool) -> Void
    let retry: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Choose experimental features for all folders.").foregroundStyle(.secondary)
                if let snapshot = model.snapshot {
                    ForEach(snapshot.features) { feature in
                        Toggle(isOn: Binding(get: { feature.enabled }, set: { change(feature.id, $0) })) {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 8) {
                                    Text(feature.title).font(.headline)
                                    if feature.id == .crossAgentMemoryConsolidation {
                                        Text("Beta").font(.caption.weight(.medium))
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(.quaternary, in: .capsule)
                                            .accessibilityIdentifier("crossAgentMemoryBeta")
                                    }
                                }
                                Text(feature.description).font(.callout).foregroundStyle(.secondary)
                                if feature.id == .crossAgentMemoryConsolidation {
                                    Text("Off by default. Enable to try cross-agent memory sharing.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .toggleStyle(.switch)
                        .accessibilityLabel(
                            feature.id == .crossAgentMemoryConsolidation ? "\(feature.title), Beta" : feature.title
                        )
                        .accessibilityIdentifier("experimentalFeature-\(feature.id.rawValue)")
                        .disabled(configurationHasChanges || model.isSaving || model.needsApply)
                    }
                    Text("Changes save and apply immediately. Running work stays intact.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if model.failure == nil {
                    ProgressView("Loading experimental features…")
                }
                if configurationHasChanges {
                    Label(
                        "Save or discard configuration edits before changing experimental features.",
                        systemImage: "pencil"
                    )
                    .font(.callout).foregroundStyle(.secondary)
                    .accessibilityIdentifier("experimentalUnsavedConfiguration")
                }
                if model.isSaving { ProgressView("Applying…").controlSize(.small) }
                if let failure = model.failure {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(failure).foregroundStyle(.red).textSelection(.enabled)
                            .accessibilityIdentifier("experimentalFailure")
                        Button(model.needsApply ? "Apply Again" : "Reload Experimental Features", action: retry)
                            .accessibilityIdentifier("retryExperimental")
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
        .accessibilityIdentifier("experimentalPanel")
    }
}
