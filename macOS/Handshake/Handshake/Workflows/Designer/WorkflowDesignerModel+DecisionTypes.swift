import SwiftUI

/// Answer types change the interpretation of existing wires without deleting them.
extension WorkflowDesignerModel {
    func decisionEdges(_ id: String) -> [CoreWorkflowType.Edge] {
        let edges = definition.graph?.agentEdges.filter { $0.from == id } ?? []
        let ordered = (definition.graph?.decisions[id]?.options ?? []).compactMap { option in
            edges.first { $0.output == option.id } ?? edges.first { $0.id == option.id }
        }
        let orderedIDs = Set(ordered.map(\.id))
        return ordered + edges.filter { !orderedIDs.contains($0.id) }
    }

    func setDecisionKind(_ id: String, kind: CoreWorkflowType.DecisionKind) {
        guard var graph = definition.graph, graph.decisions[id]?.kind != kind else { return }
        let names = Dictionary(uniqueKeysWithValues: definition.roles.map { ($0.id, $0.name) })
        decisionDrafts.switchKind(
            id, to: kind, edges: decisionEdges(id).filter { !$0.always }, graph: &graph, names: names)
        definition.graph = graph
    }

    func setDecisionUncertain(_ id: String, enabled: Bool) {
        guard var graph = definition.graph else { return }
        decisionDrafts.setUncertain(id, enabled: enabled, graph: &graph)
        definition.graph = graph
    }

    func assignDecisionOutput(_ id: String, edge edgeID: String, output: String) {
        guard var graph = definition.graph, graph.decisions[id]?.kind == .noul,
            let index = graph.edges.firstIndex(where: { $0.id == edgeID && $0.from == id })
        else { return }
        let previous = graph.edges[index].output
        let wasAlways = graph.edges[index].always
        graph.edges[index].always = false
        if let other = graph.edges.firstIndex(where: { $0.from == id && $0.output == output && $0.id != edgeID }) {
            graph.edges[other].output = previous
            graph.edges[other].always = wasAlways
        }
        graph.edges[index].output = output
        definition.graph = graph
    }

    func swapDecisionAnswers(_ id: String) {
        guard let yes = definition.graph?.edges.first(where: { $0.from == id && !$0.always && $0.output == "yes" })
        else { return }
        assignDecisionOutput(id, edge: yes.id, output: "no")
    }

    func moveDecisionLevel(_ id: String, option: String, to destination: Int) {
        guard var node = definition.graph?.decisions[id], node.kind == .score,
            let index = node.options.firstIndex(where: { $0.id == option })
        else { return }
        let value = node.options.remove(at: index)
        node.options.insert(value, at: min(max(0, destination), node.options.count))
        definition.graph?.decisions[id] = node
    }

    func decisionIssues(_ id: String) -> [String] {
        decisionValidation(id).map(\.message)
    }
}
