import Foundation

/// Formats an already validated core report; routing remains entirely in core.
struct WorkflowDecisionResultPresentation {
    let title: String
    let detail: String?

    static func make(
        report: String?, node: CoreWorkflowType.DecisionNode?, output: String,
        destination: String, locale: Locale = .current
    ) -> Self {
        let fallback = Self(title: "Routed to \(destination)", detail: nil)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let report, let data = report.data(using: .utf8),
            let envelope = try? decoder.decode(Envelope.self, from: data),
            envelope.version == 1, envelope.result.kind == "turn",
            let outcome = envelope.result.report.outcome.outcomes.first(where: { $0.questionId == "route" }),
            outcome.status == "answered", let answer = outcome.answer
        else { return fallback }
        switch answer.type {
        case "noul":
            guard let probability = answer.probability, probability.isFinite, (0...1).contains(probability),
                let label = node?.outputs.first(where: { $0.id == output })?.name
            else { return fallback }
            let percent = probability.formatted(.percent.precision(.fractionLength(0...2)).locale(locale))
            return .init(title: "\(label) → \(destination)", detail: "Probability of Yes: \(percent)")
        case "score":
            guard let value = answer.value, value.isFinite, let node, node.options.count >= 2,
                let index = node.options.firstIndex(where: { $0.id == output })
            else { return fallback }
            let score = value.formatted(.number.precision(.fractionLength(0...4)).locale(locale))
            return .init(
                title: "Score \(score) / \(node.options.count - 1) → \(destination)",
                detail: "Scale starts at 0; routed to level \(index).")
        case "choice":
            let title = node?.outputs.first { $0.id == output }.map { "\($0.name) → \(destination)" } ?? fallback.title
            guard let probability = answer.distribution?.first(where: { $0.optionId == output })?.probability,
                probability.isFinite, (0...1).contains(probability)
            else { return .init(title: title, detail: nil) }
            let percent = probability.formatted(.percent.precision(.fractionLength(0...2)).locale(locale))
            return .init(title: title, detail: "Option probability: \(percent)")
        default: return fallback
        }
    }

    private struct Envelope: Decodable {
        let version: Int
        let result: Turn
    }
    private struct Turn: Decodable {
        let kind: String
        let report: Report
    }
    private struct Report: Decodable { let outcome: Outcome }
    private struct Outcome: Decodable { let outcomes: [AnswerRow] }
    private struct AnswerRow: Decodable {
        let questionId: String
        let status: String
        let answer: Answer?
    }
    private struct Answer: Decodable {
        let type: String
        let probability: Double?
        let value: Double?
        let distribution: [OptionProbability]?
    }
    private struct OptionProbability: Decodable {
        let optionId: String
        let probability: Double
    }
}
