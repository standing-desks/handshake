import SwiftUI

/// Choice text and its destination have separate identities and lifetimes.
extension WorkflowDesignerModel {
    static func newChoiceOption(in options: [CoreWorkflowType.DecisionOption]) -> CoreWorkflowType.DecisionOption {
        var number = 1
        while options.contains(where: { $0.name == "Option \(number)" }) { number += 1 }
        let name = "Option \(number)"
        return .init(id: UUID().uuidString, name: name, description: name)
    }

    func addDecisionOption(_ id: String) {
        guard var graph = definition.graph, var node = graph.decisions[id], node.kind == .choice,
            node.options.count < 255
        else { return }
        let option = Self.newChoiceOption(in: node.options)
        node.options.append(option)
        if let index = graph.edges.firstIndex(where: { $0.from == id && !$0.always && $0.output == nil }) {
            graph.edges[index].output = option.id
        }
        graph.decisions[id] = node
        definition.graph = graph
    }

    func setDecisionOptionText(_ id: String, option optionID: String, text: String) {
        guard var node = definition.graph?.decisions[id], node.kind == .choice,
            let index = node.options.firstIndex(where: { $0.id == optionID })
        else { return }
        node.options[index].name = text
        node.options[index].description = text
        definition.graph?.decisions[id] = node
    }

    func removeDecisionOption(_ id: String, option optionID: String) {
        guard var graph = definition.graph, var node = graph.decisions[id], node.kind == .choice else { return }
        node.options.removeAll { $0.id == optionID }
        for index in graph.edges.indices where graph.edges[index].from == id && graph.edges[index].output == optionID {
            graph.edges[index].output = nil
        }
        graph.decisions[id] = node
        definition.graph = graph
    }
}
