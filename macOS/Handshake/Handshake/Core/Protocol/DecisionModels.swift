import Foundation

extension CoreWorkflowType {
    struct DecisionNode: Codable, Hashable, Sendable {
        var question = "Which output matches the incoming work?"
        var kind: DecisionKind = .choice
        var options: [DecisionOption] = []
        var trueThreshold = 8_000
        var falseThreshold = 2_000
        var minConfidence: Int?
        var provider: String?
        var model: String?
        var includeTask = true

        var outputs: [DecisionOutput] {
            if kind == .noul {
                var values = [DecisionOutput(id: "yes", name: "Yes"), .init(id: "no", name: "No")]
                if trueThreshold > falseThreshold { values.append(.init(id: "uncertain", name: "Uncertain")) }
                return values
            }
            var values = options.map { DecisionOutput(id: $0.id, name: $0.name) }
            if minConfidence != nil { values.append(.init(id: "fallback", name: "Fallback")) }
            return values
        }

    }

    enum DecisionKind: String, Codable, CaseIterable, Sendable {
        case choice, noul, score

        var title: String {
            switch self {
            case .choice: "Multiple choice"
            case .noul: "Yes/No"
            case .score: "Score"
            }
        }

        var shortTitle: String { self == .choice ? "Choice" : title }

    }

    struct DecisionOption: Codable, Hashable, Identifiable, Sendable {
        var id: String
        var name: String
        var description: String
    }

    struct DecisionOutput: Hashable, Identifiable, Sendable {
        let id: String
        let name: String
    }
}

extension CoreWorkflowType.DecisionNode {
    private enum CodingKeys: String, CodingKey {
        case question, kind, options, provider, model
        case trueThreshold = "true_threshold"
        case falseThreshold = "false_threshold"
        case minConfidence = "min_confidence"
        case includeTask = "include_task"
    }
}
