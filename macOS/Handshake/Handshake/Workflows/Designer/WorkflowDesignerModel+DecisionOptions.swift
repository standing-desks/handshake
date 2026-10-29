import SwiftUI

/// Authored Choice and Score options have identities independent of their receiving agents.
extension WorkflowDesignerModel {
    static func newChoiceOption(in options: [CoreWorkflowType.DecisionOption]) -> CoreWorkflowType.DecisionOption {
        var number = 1
        while options.contains(where: { $0.name == "Option \(number)" }) { number += 1 }
        let name = "Option \(number)"
        return .init(id: UUID().uuidString, name: name, description: name)
    }

    @discardableResult
    func addDecisionOption(_ id: String, edge edgeID: String? = nil, text: String? = nil) -> String? {
        guard var graph = definition.graph, var node = graph.decisions[id], node.kind != .noul,
            node.options.count < (node.kind == .score ? 10 : 255)
        else { return nil }
        var option = Self.newChoiceOption(in: node.options)
        if let text {
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.utf8.count <= 8_192 else { return nil }
            option.name = text
            option.description = text
        }
        if let edgeID {
            guard let index = graph.edges.firstIndex(where: { $0.from == id && $0.id == edgeID }) else { return nil }
            graph.edges[index].output = option.id
            graph.edges[index].always = false
        } else if let index = graph.edges.firstIndex(where: { $0.from == id && !$0.always && $0.output == nil }) {
            graph.edges[index].output = option.id
        }
        node.options.append(option)
        if node.kind == .score { node.scoreThresholds = nil }
        graph.decisions[id] = node
        definition.graph = graph
        return option.id
    }

    func setDecisionOptionText(_ id: String, option optionID: String, text: String) {
        guard var node = definition.graph?.decisions[id], node.kind != .noul,
            let index = node.options.firstIndex(where: { $0.id == optionID })
        else { return }
        node.options[index].name = text
        node.options[index].description = text
        definition.graph?.decisions[id] = node
    }

    func removeDecisionOption(_ id: String, option optionID: String) {
        guard var graph = definition.graph, var node = graph.decisions[id], node.kind != .noul,
            node.options.contains(where: { $0.id == optionID })
        else { return }
        node.options.removeAll { $0.id == optionID }
        if node.kind == .score { node.scoreThresholds = nil }
        for index in graph.edges.indices where graph.edges[index].from == id && graph.edges[index].output == optionID {
            graph.edges[index].output = nil
        }
        graph.decisions[id] = node
        definition.graph = graph
    }

    func cancelDecisionOptionCreation(_ optionID: String, restoring previous: CoreWorkflowType.Edge) {
        guard var graph = definition.graph, var node = graph.decisions[previous.from], node.kind == .choice,
            node.options.contains(where: { $0.id == optionID })
        else { return }
        node.options.removeAll { $0.id == optionID }
        let available = previous.output.flatMap { output in
            node.outputs.contains { $0.id == output }
                && !graph.edges.contains { $0.from == previous.from && $0.id != previous.id && $0.output == output }
                ? output : nil
        }
        for index in graph.edges.indices where graph.edges[index].from == previous.from {
            guard graph.edges[index].output == optionID else { continue }
            graph.edges[index].output = nil
            if graph.edges[index].id == previous.id {
                graph.edges[index].always = previous.always
                graph.edges[index].output = previous.always ? nil : available
            }
        }
        graph.decisions[previous.from] = node
        definition.graph = graph
    }
}
