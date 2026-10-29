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
        guard var graph = definition.graph, var node = graph.decisions[id], node.kind != kind else { return }
        let edges = decisionEdges(id)
        node.kind = kind
        node.minConfidence = nil
        node.options = edges.map { .init(id: $0.id, name: nodeName($0.to), description: nodeName($0.to)) }
        if kind == .noul {
            node.trueThreshold = 5_000
            node.falseThreshold = 5_000
        }
        for index in graph.edges.indices where graph.edges[index].from == id {
            let edge = graph.edges[index]
            let rank = edges.firstIndex { $0.id == edge.id } ?? edges.count
            graph.edges[index].output =
                kind == .noul
                ? (rank < 2 ? ["yes", "no"][rank] : nil) : edge.id
        }
        graph.decisions[id] = node
        definition.graph = graph
    }

    func setDecisionUncertain(_ id: String, enabled: Bool) {
        guard var graph = definition.graph, var node = graph.decisions[id], node.kind == .noul else { return }
        node.trueThreshold = enabled ? 8_000 : 5_000
        node.falseThreshold = enabled ? 2_000 : 5_000
        graph.decisions[id] = node
        normalizeBinaryMappings(id, outputs: node.outputs.map(\.id), graph: &graph)
        definition.graph = graph
    }

    private func normalizeBinaryMappings(_ id: String, outputs: [String], graph: inout CoreWorkflowType.Graph) {
        var used = Set<String>()
        for index in graph.edges.indices where graph.edges[index].from == id {
            if let output = graph.edges[index].output, outputs.contains(output), used.insert(output).inserted {
                continue
            }
            graph.edges[index].output = nil
        }
        for index in graph.edges.indices where graph.edges[index].from == id && graph.edges[index].output == nil {
            if let output = outputs.first(where: { !used.contains($0) }) {
                graph.edges[index].output = output
                used.insert(output)
            }
        }
    }

    func assignDecisionOutput(_ id: String, edge edgeID: String, output: String) {
        guard var graph = definition.graph, graph.decisions[id]?.kind == .noul,
            let index = graph.edges.firstIndex(where: { $0.id == edgeID && $0.from == id })
        else { return }
        let previous = graph.edges[index].output
        if let other = graph.edges.firstIndex(where: { $0.from == id && $0.output == output && $0.id != edgeID }) {
            graph.edges[other].output = previous
        }
        graph.edges[index].output = output
        definition.graph = graph
    }

    func swapDecisionAnswers(_ id: String) {
        guard let yes = definition.graph?.edges.first(where: { $0.from == id && $0.output == "yes" }) else { return }
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
        guard let node = definition.graph?.decisions[id] else { return [] }
        let edges = decisionEdges(id)
        if edges.count == 1 { return [] }
        if edges.isEmpty { return ["Connect an output. One connection passes work through."] }
        switch node.kind {
        case .choice: return []
        case .noul:
            let expected = node.outputs.map(\.id)
            var issues: [String] = []
            if edges.count != expected.count {
                issues.append(
                    "Yes/No needs \(expected.count) connections. Existing wires are kept; adjust the connections.")
            }
            for output in node.outputs where edges.filter({ $0.output == output.id }).count != 1 {
                issues.append("Assign one connected agent to \(output.name).")
            }
            if edges.contains(where: { !expected.contains($0.output ?? "") }) {
                issues.append("Some connections have no answer assigned.")
            }
            return issues
        case .score:
            return (2...10).contains(edges.count) ? [] : ["Score needs between 2 and 10 connected levels."]
        }
    }
}
