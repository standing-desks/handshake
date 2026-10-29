import SwiftUI

/// Enum tags keep the Always delivery separate from arbitrary authored option IDs.
private enum WorkflowDecisionEdgeSelection: Hashable {
    case unassigned, always, newChoice
    case option(String)
}

struct WorkflowDecisionChoiceCreation {
    let option: String
    let previous: CoreWorkflowType.Edge

    func isValid(in definition: CoreWorkflowType.Definition) -> Bool {
        guard let graph = definition.graph, let node = graph.decisions[previous.from], node.kind == .choice,
            node.options.contains(where: { $0.id == option })
        else { return false }
        return graph.edges.contains {
            $0.id == previous.id && $0.from == previous.from && $0.output == option && !$0.always
        }
    }
}

struct WorkflowDecisionEdgeOutputPicker: View {
    let model: WorkflowDesignerModel
    let edge: CoreWorkflowType.Edge
    let close: () -> Void
    let cancel: () -> Void
    @Binding var creation: WorkflowDecisionChoiceCreation?

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
                case .unassigned: model.assignDecisionOutput(edge.from, edge: edge.id, output: nil)
                case .newChoice:
                    let previous = current
                    if let option = model.addDecisionOption(edge.from, edge: edge.id) {
                        creation = .init(option: option, previous: previous)
                    }
                }
                if value != .newChoice { creation = nil }
            })
    }

    var body: some View {
        if let creation {
            WorkflowDecisionChoiceTextField(
                model: model, node: edge.from, option: creation.option, finish: close, cancel: cancel
            ).id(creation.option)
        } else {
            outputPicker
            if current.always {
                Text("Receives work after every successful decision.").font(.caption).foregroundStyle(.secondary)
            } else if model.decisionEdges(edge.from).count == 1 {
                Text("Passthrough: forward inputs directly.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var outputPicker: some View {
        Picker("Output", selection: selection) {
            Text("Unassigned").tag(WorkflowDecisionEdgeSelection.unassigned)
            ForEach(model.definition.graph?.decisions[edge.from]?.outputs ?? []) { output in
                Text(outputName(output))
                    .tag(WorkflowDecisionEdgeSelection.option(output.id))
            }
            Divider()
            Label("Always", systemImage: "arrow.triangle.branch").tag(WorkflowDecisionEdgeSelection.always)
            if let node = model.definition.graph?.decisions[edge.from], node.kind == .choice {
                Divider()
                Label("New choice…", systemImage: "plus").tag(WorkflowDecisionEdgeSelection.newChoice)
                    .disabled(node.options.count >= 255)
            }
        }.accessibilityIdentifier("decisionEdgeOutput")
    }

    private func outputName(_ output: CoreWorkflowType.DecisionOutput) -> String {
        guard let node = model.definition.graph?.decisions[edge.from], node.kind == .score,
            let index = node.options.firstIndex(where: { $0.id == output.id })
        else { return output.name.isEmpty ? "Untitled option" : output.name }
        return WorkflowDecisionLabels.scoreOutputTitle(node, index: index)
    }

}

private struct WorkflowDecisionChoiceTextField: View {
    let model: WorkflowDesignerModel
    let node: String
    let option: String
    let finish: () -> Void
    let cancel: () -> Void
    @State private var selection: TextSelection?
    @FocusState private var focused: Bool

    private var text: Binding<String> {
        Binding(
            get: { model.definition.graph?.decisions[node]?.options.first { $0.id == option }?.name ?? "" },
            set: { model.setDecisionOptionText(node, option: option, text: $0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Choice text").font(.caption).foregroundStyle(.secondary)
            TextField("Choice text", text: text, selection: $selection).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Choice text").accessibilityIdentifier("decisionNewChoiceText")
                .focused($focused).onSubmit(finish).onExitCommand(perform: cancel)
                .task {
                    focused = true
                    let value = text.wrappedValue
                    selection = TextSelection(range: value.startIndex..<value.endIndex)
                }
            if let issue = model.decisionValidation(node).first(where: { $0.field == .answer(option) }) {
                WorkflowDecisionIssueLabel(issue: issue)
            }
        }
    }
}
