import SwiftUI

struct WorkflowNodeKindPicker: View {
    let model: WorkflowDesignerModel
    let id: String

    var body: some View {
        Picker(
            "Node type",
            selection: Binding(
                get: { model.definition.graph?.decisions[id] != nil },
                set: { model.setDecision(id, enabled: $0) })
        ) {
            Text("Agent").tag(false)
            Text("Decision").tag(true)
        }
        .pickerStyle(.segmented).accessibilityIdentifier("graphNodeKind")
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 6)
    }
}
