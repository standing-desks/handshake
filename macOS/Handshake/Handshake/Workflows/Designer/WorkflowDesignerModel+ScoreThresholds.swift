import Foundation

extension WorkflowDesignerModel {
    func setDecisionScoreThreshold(_ id: String, index: Int, value: Int) {
        guard var node = definition.graph?.decisions[id], node.kind == .score else { return }
        var cutoffs = node.effectiveScoreThresholds
        guard cutoffs.indices.contains(index) else { return }
        let lower = index == 0 ? 0 : cutoffs[index - 1]
        let upper = index + 1 == cutoffs.count ? (node.options.count - 1) * 10_000 : cutoffs[index + 1]
        guard value > lower && value < upper else { return }
        cutoffs[index] = value
        node.scoreThresholds = cutoffs
        definition.graph?.decisions[id] = node
    }
}
