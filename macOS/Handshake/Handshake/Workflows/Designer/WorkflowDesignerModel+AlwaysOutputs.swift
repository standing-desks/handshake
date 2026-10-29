import SwiftUI

extension WorkflowDesignerModel {
    func usesAlwaysOutputs(_ id: String) -> Bool {
        alwaysOutputSettings.contains(id) || decisionEdges(id).contains(where: \.always)
    }

    func setAlwaysOutputs(_ id: String, enabled: Bool) {
        if enabled {
            alwaysOutputSettings.insert(id)
        } else {
            alwaysOutputSettings.remove(id)
            for edge in decisionEdges(id) where edge.always { setDecisionAlways(id, edge: edge.id, enabled: false) }
        }
    }

    func setDecisionAlways(_ id: String, edge edgeID: String, enabled: Bool) {
        guard var graph = definition.graph, var node = graph.decisions[id],
            let index = graph.edges.firstIndex(where: { $0.from == id && $0.id == edgeID }),
            graph.edges[index].always != enabled
        else { return }
        let edge = graph.edges[index]
        let score = node.kind == .score
        if node.kind != .choice {
            node.options.removeAll { score ? $0.id == edge.output : $0.id == edge.id }
        }
        graph.edges[index].always = enabled
        if enabled {
            graph.edges[index].output = nil
            alwaysOutputSettings.insert(id)
        } else {
            let name = nodeName(edge.to)
            var levelID = edge.id
            if node.options.contains(where: { $0.id == levelID }) { levelID = UUID().uuidString }
            if node.kind != .choice { node.options.append(.init(id: levelID, name: name, description: name)) }
            let used = Set(graph.edges.filter { $0.from == id && !$0.always && $0.id != edgeID }.compactMap(\.output))
            graph.edges[index].output = node.kind == .score ? levelID : node.outputs.first { !used.contains($0.id) }?.id
        }
        graph.decisions[id] = node
        definition.graph = graph
    }
}
