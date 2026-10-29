import SwiftUI

/// Actionable form feedback supplements core's authoritative workflow validation.
struct WorkflowDecisionIssue: Equatable, Identifiable {
    enum Field: Hashable {
        case question, connections
        case answer(String)
    }
    let nodeID: String
    let field: Field
    let message: String
    var id: String { "\(nodeID)-\(field)" }
}

extension WorkflowDesignerModel {
    var decisionValidationIssues: [WorkflowDecisionIssue] {
        definition.roles.flatMap { decisionValidation($0.id) }
    }

    func decisionValidation(_ id: String) -> [WorkflowDecisionIssue] {
        guard let node = definition.graph?.decisions[id] else { return [] }
        let connections = decisionEdges(id)
        if connections.count == 1 { return [] }
        let edges = connections.filter { !$0.always }
        var issues: [WorkflowDecisionIssue] = []
        if node.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(nodeID: id, field: .question, message: "Enter a question for this decision."))
        } else if node.question.utf8.count > 8_192 {
            issues.append(
                .init(nodeID: id, field: .question, message: "The question is too long. Shorten it before saving."))
        }
        if connections.isEmpty {
            issues.append(
                .init(
                    nodeID: id, field: .connections, message: "Connect an output. One connection passes work through."))
        } else if node.kind == .noul {
            for output in node.outputs where edges.filter({ $0.output == output.id }).count != 1 {
                issues.append(
                    .init(nodeID: id, field: .answer(output.id), message: "Connect one agent for \(output.name)."))
            }
            if edges.count > node.outputs.count {
                issues.append(
                    .init(
                        nodeID: id, field: .connections,
                        message:
                            "Yes/No needs \(node.outputs.count) connections. Remove the extra connections."
                    ))
            }
        } else if node.kind == .choice {
            issues += choiceValidation(id, node: node, edges: edges)
        } else if node.kind == .score && !(2...10).contains(edges.count) {
            issues.append(
                .init(
                    nodeID: id, field: .connections,
                    message: "Score needs between 2 and 10 decision levels. Always outputs are not levels."))
        }
        return issues
    }
    private func choiceValidation(
        _ id: String, node: CoreWorkflowType.DecisionNode, edges: [CoreWorkflowType.Edge]
    ) -> [WorkflowDecisionIssue] {
        var issues: [WorkflowDecisionIssue] = []
        if node.options.count < 2 {
            issues.append(.init(nodeID: id, field: .connections, message: "Add at least two choices."))
        }
        for option in node.options {
            let text = option.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let message: String?
            if text.isEmpty {
                message = "Enter text for this option."
            } else if option.name.utf8.count > 8_192 {
                message = "This option is too long. Shorten its text."
            } else if edges.filter({ $0.output == option.id }).count != 1 {
                message = "Choose one connected agent for \(option.name)."
            } else {
                message = nil
            }
            if let message { issues.append(.init(nodeID: id, field: .answer(option.id), message: message)) }
        }
        if node.minConfidence != nil, edges.filter({ $0.output == "fallback" }).count != 1 {
            issues.append(
                .init(nodeID: id, field: .answer("fallback"), message: "Choose one connected agent for Fallback."))
        }
        if edges.contains(where: { edge in !node.outputs.contains { $0.id == edge.output } }) {
            issues.append(
                .init(
                    nodeID: id, field: .connections,
                    message: "Choose an option or Always for every connection."))
        }
        return issues
    }

}

struct WorkflowDecisionIssueLabel: View {
    let issue: WorkflowDecisionIssue
    var body: some View {
        Label(issue.message, systemImage: "exclamationmark.circle")
            .font(.caption).foregroundStyle(Color.statusNeedsAttention)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("decisionIssue-\(issue.id)")
    }
}
