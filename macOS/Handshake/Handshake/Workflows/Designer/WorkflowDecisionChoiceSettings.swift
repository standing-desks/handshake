import SwiftUI

/// Authored options are independent of the agents assigned to receive them.
struct WorkflowDecisionChoiceSettings: View {
    let model: WorkflowDesignerModel
    let id: String
    @Binding var decision: CoreWorkflowType.DecisionNode

    var body: some View {
        Section("Options and destinations") {
            ForEach(decision.options) { option in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        TextField(
                            "Option text",
                            text: Binding(
                                get: { decision.options.first { $0.id == option.id }?.name ?? "" },
                                set: { model.setDecisionOptionText(id, option: option.id, text: $0) })
                        ).labelsHidden().textFieldStyle(.roundedBorder).accessibilityLabel("Option text")
                            .accessibilityIdentifier("decisionOptionText-\(option.id)")
                        Picker(
                            "Destination",
                            selection: Binding(
                                get: {
                                    model.decisionEdges(id).first { !$0.always && $0.output == option.id }?.id ?? ""
                                },
                                set: { model.assignDecisionOutput(id, edge: $0, output: option.id) })
                        ) {
                            Text("Choose agent").tag("").disabled(true)
                            ForEach(model.decisionEdges(id)) { Text(model.nodeName($0.to)).tag($0.id) }
                        }.labelsHidden().frame(width: 140)
                            .accessibilityLabel("Destination for \(option.name)")
                            .accessibilityIdentifier("decisionOptionDestination-\(option.id)")
                        Button {
                            model.removeDecisionOption(id, option: option.id)
                        } label: {
                            Image(systemName: "minus.circle").frame(width: 28, height: 28).contentShape(.rect)
                        }.buttonStyle(.borderless).accessibilityLabel("Remove \(option.name)")
                    }
                    if let issue = model.decisionValidation(id).first(where: { $0.field == .answer(option.id) }) {
                        WorkflowDecisionIssueLabel(issue: issue)
                    }
                }
                .id(WorkflowDecisionIssue.Field.answer(option.id))
                .accessibilityElement(children: .contain).accessibilityIdentifier("decisionOption-\(option.id)")
            }
            if let confidence = decision.minConfidence {
                Picker(
                    "Fallback",
                    selection: Binding(
                        get: { model.decisionEdges(id).first { !$0.always && $0.output == "fallback" }?.id ?? "" },
                        set: { model.assignDecisionOutput(id, edge: $0, output: "fallback") })
                ) {
                    Text("Choose agent").tag("").disabled(true)
                    ForEach(model.decisionEdges(id)) { Text(model.nodeName($0.to)).tag($0.id) }
                }.id(WorkflowDecisionIssue.Field.answer("fallback"))
                Text("Native-confidence fallback: below \((Double(confidence) / 100).formatted())%.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("Add option", systemImage: "plus") { model.addDecisionOption(id) }
                .disabled(decision.options.count >= 255).accessibilityIdentifier("decisionAddOption")
            Text("Nouli chooses an option. Its assigned agent receives the work.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
