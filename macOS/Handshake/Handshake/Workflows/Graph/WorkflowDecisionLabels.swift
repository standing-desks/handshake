import Foundation

/// The canvas, overview, and run surface present the same answer-to-wire mapping.
enum WorkflowDecisionLabels {
    static func outputTitle(_ edge: CoreWorkflowType.Edge, definition: CoreWorkflowType.Definition) -> String {
        guard let graph = definition.graph, let node = graph.decisions[edge.from] else { return edge.event.title }
        if graph.agentEdges.filter({ $0.from == edge.from }).count == 1 { return "Passthrough" }
        let name = definition.roles.first { $0.id == edge.to }?.name ?? edge.to
        switch node.kind {
        case .choice: return name
        case .noul: return node.outputs.first { $0.id == edge.output }?.name ?? "Unassigned"
        case .score:
            guard let index = node.options.firstIndex(where: { $0.id == edge.output }) else { return "Unassigned" }
            let label = scoreLevelName(node.options[index], edge: edge, definition: definition)
            return "\(index) · \(label)"
        }
    }

    static func scoreLevelName(
        _ option: CoreWorkflowType.DecisionOption, edge: CoreWorkflowType.Edge?,
        definition: CoreWorkflowType.Definition
    ) -> String {
        guard let edge, option.id == edge.id else { return option.name }
        return definition.roles.first { $0.id == edge.to }?.name ?? edge.to
    }
}
