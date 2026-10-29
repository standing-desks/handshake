import Foundation

/// Presentation of core's exact cutoffs; selecting a route remains a core operation.
enum WorkflowDecisionScoreRanges {
    static func number(_ ticks: Int) -> String {
        (Double(ticks) / 10_000).formatted(.number.precision(.fractionLength(0...4)).grouping(.never))
    }

    static func title(_ node: CoreWorkflowType.DecisionNode, index: Int) -> String {
        let cutoffs = node.effectiveScoreThresholds
        guard node.validScoreThresholds, node.options.indices.contains(index), cutoffs.count == node.options.count - 1,
            !cutoffs.isEmpty
        else { return "Configure thresholds" }
        if index == 0 { return "score < \(number(cutoffs[0]))" }
        if index == node.options.count - 1 { return "score ≥ \(number(cutoffs[index - 1]))" }
        return "\(number(cutoffs[index - 1])) ≤ score < \(number(cutoffs[index]))"
    }
}
