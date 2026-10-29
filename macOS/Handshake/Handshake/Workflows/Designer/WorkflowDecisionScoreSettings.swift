import SwiftUI

/// Each ordered option keeps its editable routing cutoff beside its description and destination.
struct WorkflowDecisionScoreSettings: View {
    let model: WorkflowDesignerModel
    let id: String
    @Binding var decision: CoreWorkflowType.DecisionNode

    var body: some View {
        Section("Options — lowest to highest") {
            ForEach(Array(decision.options.enumerated()), id: \.element.id) { index, option in
                optionRow(option, index: index)
            }
            Button("Add option", systemImage: "plus") { model.addDecisionOption(id) }
                .disabled(decision.options.count >= 10).accessibilityIdentifier("decisionAddScoreOption")
            Text("Describe what each level means. Agent names do not affect the scale.")
                .font(.caption).foregroundStyle(.secondary)
            thresholdReset
        }
    }

    private func optionRow(_ option: CoreWorkflowType.DecisionOption, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            optionFields(option, index: index)
            if index > 0, decision.validScoreThresholds { cutoffField(index - 1) }
            HStack {
                Text(WorkflowDecisionScoreRanges.title(decision, index: index)).font(.caption).foregroundStyle(
                    .secondary)
                Spacer(minLength: 0)
                levelButton("chevron.up", label: "Move \(option.name) up", disabled: index == 0) {
                    model.moveDecisionLevel(id, option: option.id, to: index - 1)
                }
                levelButton(
                    "chevron.down", label: "Move \(option.name) down", disabled: index == decision.options.count - 1
                ) {
                    model.moveDecisionLevel(id, option: option.id, to: index + 1)
                }
                levelButton("minus.circle", label: "Remove level \(index)", disabled: false) {
                    model.removeDecisionOption(id, option: option.id)
                }
            }
            if let issue = model.decisionValidation(id).first(where: { $0.field == .answer(option.id) }) {
                WorkflowDecisionIssueLabel(issue: issue)
            }
        }.id(WorkflowDecisionIssue.Field.answer(option.id))
    }

    private func optionFields(_ option: CoreWorkflowType.DecisionOption, index: Int) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(index)").monospacedDigit().foregroundStyle(.secondary).frame(width: 16)
            TextField(
                "Describe this level",
                text: Binding(
                    get: {
                        guard let current = decision.options.first(where: { $0.id == option.id }) else { return "" }
                        return current.name == current.description
                            ? current.name : "\(current.name): \(current.description)"
                    },
                    set: { model.setDecisionOptionText(id, option: option.id, text: $0) }), axis: .vertical
            ).labelsHidden().textFieldStyle(.roundedBorder).lineLimit(1...3)
                .accessibilityLabel("Level \(index) description")
                .accessibilityIdentifier("decisionScoreOptionText-\(option.id)")
            Picker(
                "Destination",
                selection: Binding(
                    get: { model.decisionEdges(id).first { !$0.always && $0.output == option.id }?.id ?? "" },
                    set: { model.assignDecisionOutput(id, edge: $0, output: option.id) })
            ) {
                Text("Choose agent").tag("").disabled(true)
                ForEach(model.decisionEdges(id)) { Text(model.nodeName($0.to)).tag($0.id) }
            }.labelsHidden().frame(width: 125).accessibilityLabel("Destination for level \(index)")
                .accessibilityIdentifier("decisionScoreDestination-\(option.id)")
        }
    }

    private func levelButton(
        _ symbol: String, label: String, disabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 28, height: 28).contentShape(.rect)
        }.buttonStyle(.borderless).disabled(disabled).accessibilityLabel(label)
    }

    private func cutoffField(_ index: Int) -> some View {
        WorkflowDecisionThresholdField(
            title: "Level \(index + 1) starts at",
            value: Binding(
                get: {
                    let cutoffs = decision.effectiveScoreThresholds
                    return cutoffs.indices.contains(index) ? cutoffs[index] : 0
                },
                set: { model.setDecisionScoreThreshold(id, index: index, value: $0) }),
            range: thresholdRange(index), identifier: "decisionScoreThreshold-\(index)",
            scale: 10_000, suffix: nil, step: 1_000
        )
    }

    private var thresholdReset: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let issue = model.decisionValidation(id).first(where: { $0.field == .thresholds }) {
                WorkflowDecisionIssueLabel(issue: issue)
            }
            Button("Reset thresholds") { decision.scoreThresholds = nil }
                .disabled(decision.scoreThresholds == nil).accessibilityIdentifier("decisionResetScoreThresholds")
            Text("Midpoints are the defaults. Scores at a cutoff go to the higher option.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Adding or removing an option restores midpoint thresholds.")
                .font(.caption).foregroundStyle(.secondary)
        }.id(WorkflowDecisionIssue.Field.thresholds)
    }

    private func thresholdRange(_ index: Int) -> ClosedRange<Int> {
        let cutoffs = decision.effectiveScoreThresholds
        let lower = index == 0 ? 0 : cutoffs[index - 1]
        let upper = index + 1 == cutoffs.count ? (decision.options.count - 1) * 10_000 : cutoffs[index + 1]
        return (lower + 1)...(upper - 1)
    }
}
