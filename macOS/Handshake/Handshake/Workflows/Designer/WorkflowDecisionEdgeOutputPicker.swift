import SwiftUI

/// Enum tags keep the Always delivery separate from arbitrary authored option IDs.
private enum WorkflowDecisionEdgeSelection: Hashable {
    case unassigned, always
    case option(String)
}

struct WorkflowDecisionEdgeOutputPicker: View {
    let model: WorkflowDesignerModel
    let edge: CoreWorkflowType.Edge

    private var current: CoreWorkflowType.Edge {
        model.decisionEdges(edge.from).first { $0.id == edge.id } ?? edge
    }
    private var selection: Binding<WorkflowDecisionEdgeSelection> {
        Binding(
            get: {
                if current.always { return .always }
                return current.output.map { .option($0) } ?? .unassigned
            },
            set: { value in
                switch value {
                case .always: model.setDecisionAlways(edge.from, edge: edge.id, enabled: true)
                case .option(let output): model.assignDecisionOutput(edge.from, edge: edge.id, output: output)
                case .unassigned: break
                }
            })
    }

    var body: some View {
        Picker("Output", selection: selection) {
            Text("Unassigned").tag(WorkflowDecisionEdgeSelection.unassigned).disabled(true)
            ForEach(model.definition.graph?.decisions[edge.from]?.outputs ?? []) { output in
                Text(outputName(output))
                    .tag(WorkflowDecisionEdgeSelection.option(output.id))
            }
            Divider()
            Label("Always", systemImage: "arrow.triangle.branch").tag(WorkflowDecisionEdgeSelection.always)
        }.accessibilityIdentifier("decisionEdgeOutput")
        if current.always {
            Text("Receives work after every successful decision.").font(.caption).foregroundStyle(.secondary)
        } else if model.decisionEdges(edge.from).count == 1 {
            Text("Passthrough: forward inputs directly.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func outputName(_ output: CoreWorkflowType.DecisionOutput) -> String {
        guard let node = model.definition.graph?.decisions[edge.from], node.kind == .score,
            let index = node.options.firstIndex(where: { $0.id == output.id })
        else { return output.name.isEmpty ? "Untitled option" : output.name }
        let route = model.decisionEdges(edge.from).first { !$0.always && $0.output == output.id }
        let name = WorkflowDecisionLabels.scoreLevelName(node.options[index], edge: route, definition: model.definition)
        return "\(index) · \(name)"
    }

}
