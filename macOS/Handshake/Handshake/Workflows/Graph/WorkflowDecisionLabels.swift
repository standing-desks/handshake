import Foundation

/// The canvas, overview, and run surface present the same answer-to-wire mapping.
enum WorkflowDecisionLabels {
    static func outputTitle(_ edge: CoreWorkflowType.Edge, definition: CoreWorkflowType.Definition) -> String {
        guard let graph = definition.graph, let node = graph.decisions[edge.from] else { return edge.event.title }
        if edge.always { return "Always" }
        if graph.agentEdges.filter({ $0.from == edge.from }).count == 1 { return "Passthrough" }
        switch node.kind {
        case .choice:
            guard let label = node.outputs.first(where: { $0.id == edge.output })?.name else { return "Unassigned" }
            return label.isEmpty ? "Untitled option" : label
        case .noul: return node.outputs.first { $0.id == edge.output }?.name ?? "Unassigned"
        case .score:
            guard let index = node.options.firstIndex(where: { $0.id == edge.output }) else { return "Unassigned" }
            return scoreOutputTitle(node, index: index)
        }
    }

    static func scoreOutputTitle(_ node: CoreWorkflowType.DecisionNode, index: Int) -> String {
        "\(index) · \(node.options[index].name) · \(WorkflowDecisionScoreRanges.title(node, index: index))"
    }
}
