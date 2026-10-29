import SwiftUI

/// Each answer type exposes only the mapping it needs for the connected agents.
struct WorkflowDecisionAnswerSettings: View {
    let model: WorkflowDesignerModel
    let id: String
    @Binding var decision: CoreWorkflowType.DecisionNode

    private var edges: [CoreWorkflowType.Edge] { model.decisionEdges(id).filter { !$0.always } }
    private var uncertain: Bool { decision.trueThreshold > decision.falseThreshold }

    var body: some View {
        switch decision.kind {
        case .choice: choiceSettings
        case .noul: binarySettings
        case .score: scoreSettings
        }
        if let issue = model.decisionValidation(id).first(where: { $0.field == .connections }) {
            Section { WorkflowDecisionIssueLabel(issue: issue) }.id(WorkflowDecisionIssue.Field.connections)
        }
    }

    private var choiceSettings: some View {
        WorkflowDecisionChoiceSettings(model: model, id: id, decision: $decision)
    }

    private var binarySettings: some View {
        Group {
            Section("Destinations") {
                ForEach(decision.outputs) { output in
                    Picker(
                        output.name,
                        selection: Binding(
                            get: { edges.first { $0.output == output.id }?.id ?? "" },
                            set: { model.assignDecisionOutput(id, edge: $0, output: output.id) })
                    ) {
                        Text("Choose connected agent").tag("").disabled(true)
                        ForEach(edges) { edge in Text(model.nodeName(edge.to)).tag(edge.id) }
                    }.accessibilityIdentifier("decisionAnswer-\(output.id)")
                        .id(WorkflowDecisionIssue.Field.answer(output.id))
                    if let issue = model.decisionValidation(id).first(where: { $0.field == .answer(output.id) }) {
                        WorkflowDecisionIssueLabel(issue: issue)
                    }
                }
                Button("Swap Yes / No") { model.swapDecisionAnswers(id) }
                    .disabled(!edges.contains { $0.output == "yes" } || !edges.contains { $0.output == "no" })
                    .accessibilityIdentifier("decisionSwapAnswers")
            }
            probabilitySettings
        }
    }

    private var probabilitySettings: some View {
        Section("Probability of Yes") {
            Toggle(
                "Use an Uncertain answer",
                isOn: Binding(get: { uncertain }, set: { model.setDecisionUncertain(id, enabled: $0) })
            ).toggleStyle(.checkbox).accessibilityIdentifier("decisionUncertain")
            if uncertain {
                WorkflowDecisionThresholdField(
                    title: "Yes at or above", value: $decision.trueThreshold,
                    range: (decision.falseThreshold + 1)...10_000, identifier: "decisionYesThreshold")
                WorkflowDecisionThresholdField(
                    title: "No at or below", value: $decision.falseThreshold,
                    range: 0...(decision.trueThreshold - 1), identifier: "decisionNoThreshold")
                Text("Between these thresholds, work goes to Uncertain.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                WorkflowDecisionThresholdField(
                    title: "Yes at or above",
                    value: Binding(
                        get: { decision.trueThreshold },
                        set: {
                            decision.trueThreshold = $0
                            decision.falseThreshold = $0
                        }),
                    range: 0...10_000, identifier: "decisionYesThreshold")
                Text("Below this threshold, work goes to No.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var scoreSettings: some View {
        WorkflowDecisionScoreSettings(model: model, id: id, decision: $decision)
    }
}
