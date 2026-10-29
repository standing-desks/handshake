import SwiftUI

/// Always destinations are optional and never appear in Nouli's choice or score scale.
struct WorkflowDecisionAlwaysSettings: View {
    let model: WorkflowDesignerModel
    let id: String

    var body: some View {
        Section {
            Toggle(
                "Use Always outputs",
                isOn: Binding(
                    get: { model.usesAlwaysOutputs(id) },
                    set: { model.setAlwaysOutputs(id, enabled: $0) })
            ).toggleStyle(.checkbox).accessibilityIdentifier("decisionAlwaysEnabled")
            if model.usesAlwaysOutputs(id) {
                ForEach(model.definition.graph?.agentEdges.filter { $0.from == id } ?? []) { edge in
                    Toggle(
                        model.nodeName(edge.to),
                        isOn: Binding(
                            get: { model.decisionEdges(id).first { $0.id == edge.id }?.always ?? false },
                            set: { model.setDecisionAlways(id, edge: edge.id, enabled: $0) })
                    ).toggleStyle(.checkbox).accessibilityIdentifier("decisionAlways-\(edge.id)")
                }
                Text(
                    "Selected agents receive work after every successful decision."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
