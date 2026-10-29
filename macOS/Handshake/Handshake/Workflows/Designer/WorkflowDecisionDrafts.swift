import Foundation

/// Inactive answer forms are presentation drafts; only the active definition is saved to core.
struct WorkflowDecisionDrafts {
    private struct Draft {
        let node: CoreWorkflowType.DecisionNode
        let outputs: [String: String]

        init(_ node: CoreWorkflowType.DecisionNode, edges: [CoreWorkflowType.Edge]) {
            self.node = node
            outputs = Dictionary(uniqueKeysWithValues: edges.compactMap { edge in edge.output.map { (edge.id, $0) } })
        }
    }

    private var modes: [String: [CoreWorkflowType.DecisionKind: Draft]] = [:]
    private var binary: [String: [Bool: Draft]] = [:]

    mutating func switchKind(
        _ id: String, to kind: CoreWorkflowType.DecisionKind, edges: [CoreWorkflowType.Edge],
        graph: inout CoreWorkflowType.Graph, names: [String: String]
    ) {
        guard var node = graph.decisions[id], node.kind != kind else { return }
        modes[id, default: [:]][node.kind] = Draft(node, edges: edges)
        let draft = modes[id]?[kind]
        node.kind = kind
        node.minConfidence = draft?.node.minConfidence
        node.trueThreshold = draft?.node.trueThreshold ?? 5_000
        node.falseThreshold = draft?.node.falseThreshold ?? 5_000
        if kind == .choice {
            node.options = draft?.node.options ?? []
            if draft == nil {
                for _ in 0..<max(2, edges.count) {
                    node.options.append(WorkflowDesignerModel.newChoiceOption(in: node.options))
                }
            }
            assignChoice(node: node, edges: edges, previous: draft?.outputs ?? [:], graph: &graph)
        } else {
            node.options = options(from: draft, edges: edges, names: names)
            if kind == .noul {
                assignBinary(id, node: node, previous: draft?.outputs ?? [:], graph: &graph)
            } else {
                for index in graph.edges.indices where graph.edges[index].from == id && !graph.edges[index].always {
                    let edge = graph.edges[index]
                    let saved = draft?.outputs[edge.id]
                    graph.edges[index].output =
                        node.options.first { $0.id == saved }?.id
                        ?? node.options.first { $0.id == edge.id }?.id
                }
            }
        }
        graph.decisions[id] = node
    }

    mutating func setUncertain(_ id: String, enabled: Bool, graph: inout CoreWorkflowType.Graph) {
        guard var node = graph.decisions[id], node.kind == .noul,
            enabled != (node.trueThreshold > node.falseThreshold)
        else { return }
        let edges = graph.agentEdges.filter { $0.from == id && !$0.always }
        binary[id, default: [:]][!enabled] = Draft(node, edges: edges)
        let draft = binary[id]?[enabled]
        node.trueThreshold = draft?.node.trueThreshold ?? (enabled ? 8_000 : 5_000)
        node.falseThreshold = draft?.node.falseThreshold ?? (enabled ? 2_000 : 5_000)
        let outputs = Dictionary(uniqueKeysWithValues: edges.compactMap { edge in edge.output.map { (edge.id, $0) } })
        assignBinary(id, node: node, previous: draft?.outputs ?? outputs, graph: &graph)
        graph.decisions[id] = node
    }

    private func options(
        from draft: Draft?, edges: [CoreWorkflowType.Edge], names: [String: String]
    ) -> [CoreWorkflowType.DecisionOption] {
        let retained = (draft?.node.options ?? []).filter { option in
            edges.contains { draft?.outputs[$0.id] == option.id }
        }
        let retainedIDs = Set(retained.map(\.id))
        return retained
            + edges.compactMap { edge in
                if let saved = draft?.outputs[edge.id], retainedIDs.contains(saved) { return nil }
                if draft?.outputs[edge.id] == "fallback", draft?.node.minConfidence != nil { return nil }
                let name = names[edge.to] ?? edge.to
                return .init(id: edge.id, name: name, description: name)
            }
    }

    private func assignChoice(
        node: CoreWorkflowType.DecisionNode, edges: [CoreWorkflowType.Edge],
        previous: [String: String], graph: inout CoreWorkflowType.Graph
    ) {
        let outputs = node.outputs.map(\.id)
        let indices = edges.compactMap { edge in graph.edges.firstIndex { $0.id == edge.id } }
        var used = Set<String>()
        for index in indices {
            let saved = previous[graph.edges[index].id]
            graph.edges[index].output = saved.flatMap { outputs.contains($0) && used.insert($0).inserted ? $0 : nil }
        }
        for index in indices where graph.edges[index].output == nil {
            if let output = outputs.first(where: { !used.contains($0) }) {
                graph.edges[index].output = output
                used.insert(output)
            }
        }
    }

    private func assignBinary(
        _ id: String, node: CoreWorkflowType.DecisionNode, previous: [String: String],
        graph: inout CoreWorkflowType.Graph
    ) {
        let outputs = node.outputs.map(\.id)
        var used = Set<String>()
        for index in graph.edges.indices where graph.edges[index].from == id && !graph.edges[index].always {
            let saved = previous[graph.edges[index].id]
            graph.edges[index].output = saved.flatMap { outputs.contains($0) && used.insert($0).inserted ? $0 : nil }
        }
        for index in graph.edges.indices
        where graph.edges[index].from == id && !graph.edges[index].always && graph.edges[index].output == nil {
            if let output = outputs.first(where: { !used.contains($0) }) {
                graph.edges[index].output = output
                used.insert(output)
            }
        }
    }
}
