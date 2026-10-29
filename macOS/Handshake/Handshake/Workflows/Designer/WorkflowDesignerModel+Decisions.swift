import SwiftUI

extension WorkflowDesignerModel {
    func setDecision(_ id: String, enabled: Bool) {
        guard var graph = definition.graph, definition.roles.contains(where: { $0.id == id }),
            enabled != (graph.decisions[id] != nil)
        else { return }
        if enabled {
            var node = CoreWorkflowType.DecisionNode()
            for index in graph.edges.indices where graph.edges[index].from == id {
                let edge = graph.edges[index]
                node.options.append(.init(id: edge.id, name: nodeName(edge.to), description: ""))
                graph.edges[index].output = edge.id
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
            }
        }
        definition.graph = graph
    }

    func appendDecisionRoute(_ id: String, to destination: String) {
        let link = UUID().uuidString
        let option = CoreWorkflowType.DecisionOption(id: link, name: nodeName(destination), description: "")
        definition.graph?.decisions[id]?.options.append(option)
        definition.graph?.edges.append(.init(id: link, from: id, to: destination, event: .done, output: link))
    }

    func removeGraphEdge(_ id: String) {
        guard let edge = definition.graph?.edges.first(where: { $0.id == id }) else { return }
        definition.graph?.edges.removeAll { $0.id == id }
        if let output = edge.output {
            definition.graph?.decisions[edge.from]?.options.removeAll { $0.id == output }
        }
    }

    func routeCriterion(_ edge: CoreWorkflowType.Edge) -> Binding<String> {
        Binding(
            get: {
                self.definition.graph?.decisions[edge.from]?.options.first { $0.id == edge.output }?.description ?? ""
            },
            set: { value in
                guard
                    let index = self.definition.graph?.decisions[edge.from]?.options.firstIndex(where: {
                        $0.id == edge.output
                    })
                else { return }
                self.definition.graph?.decisions[edge.from]?.options[index].description = value
            })
    }

    func nodeName(_ id: String) -> String { definition.roles.first { $0.id == id }?.name ?? id }

    func outputTitle(_ edge: CoreWorkflowType.Edge) -> String {
        guard let decision = definition.graph?.decisions[edge.from] else { return edge.event.title }
        if definition.graph?.agentEdges.filter({ $0.from == edge.from }).count == 1 { return "Passthrough" }
        return decision.kind == .choice && decision.minConfidence == nil
            ? nodeName(edge.to) : decision.outputs.first { $0.id == edge.output }?.name ?? "Route"
    }

    func connectDecision(_ id: String, output: String, to destination: String) {
        definition.graph?.edges.removeAll { $0.from == id && $0.output == output }
        guard !destination.isEmpty else { return }
        definition.graph?.edges.append(
            .init(id: UUID().uuidString, from: id, to: destination, event: .done, output: output))
    }
}
