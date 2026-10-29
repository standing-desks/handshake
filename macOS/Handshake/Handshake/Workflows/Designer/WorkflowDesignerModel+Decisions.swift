import SwiftUI

extension WorkflowDesignerModel {
    func setDecision(_ id: String, enabled: Bool) {
        guard var graph = definition.graph, definition.roles.contains(where: { $0.id == id }),
            enabled != (graph.decisions[id] != nil)
        else { return }
        if enabled {
            var node = CoreWorkflowType.DecisionNode()
            let outgoing = graph.edges.indices.filter { graph.edges[$0].from == id }
            for _ in 0..<max(2, outgoing.count) { node.options.append(Self.newChoiceOption(in: node.options)) }
            for (rank, index) in outgoing.enumerated() {
                graph.edges[index].output = node.options[rank].id
                graph.edges[index].event = .done
            }
            graph.decisions[id] = node
            graph.reviewAgents.removeAll { $0 == id }
        } else {
            graph.decisions.removeValue(forKey: id)
            var destinations = Set<String>()
            graph.edges.removeAll { $0.from == id && !destinations.insert($0.to).inserted }
            for index in graph.edges.indices where graph.edges[index].from == id {
                graph.edges[index].output = nil
                graph.edges[index].always = false
            }
        }
        definition.graph = graph
    }

    func appendDecisionRoute(_ id: String, to destination: String) {
        let link = UUID().uuidString
        guard let node = definition.graph?.decisions[id] else { return }
        let used = Set(definition.graph?.edges.filter { $0.from == id }.compactMap(\.output) ?? [])
        let output = node.outputs.first { !used.contains($0.id) }?.id
        definition.graph?.edges.append(.init(id: link, from: id, to: destination, event: .done, output: output))
    }

    func removeGraphEdge(_ id: String) {
        guard let edge = definition.graph?.edges.first(where: { $0.id == id }) else { return }
        definition.graph?.edges.removeAll { $0.id == id }
        if let kind = definition.graph?.decisions[edge.from]?.kind, kind == .noul {
            definition.graph?.decisions[edge.from]?.options.removeAll {
                $0.id == edge.id
            }
        }
    }

    func nodeName(_ id: String) -> String { definition.roles.first { $0.id == id }?.name ?? id }

    func outputTitle(_ edge: CoreWorkflowType.Edge) -> String {
        WorkflowDecisionLabels.outputTitle(edge, definition: definition)
    }
}
