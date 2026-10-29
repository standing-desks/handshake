import SwiftUI

/// Each answer type exposes only the mapping it needs for the connected agents.
struct WorkflowDecisionAnswerSettings: View {
    let model: WorkflowDesignerModel
    let id: String
    @Binding var decision: CoreWorkflowType.DecisionNode

    private var edges: [CoreWorkflowType.Edge] { model.decisionEdges(id) }
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
        Section("Destinations") {
            ForEach(edges.filter { $0.output != "fallback" || decision.minConfidence == nil }) { edge in
                Label(model.nodeName(edge.to), systemImage: "arrow.right")
                    .accessibilityIdentifier("decisionOption-\(edge.id)")
            }
            Text("The connected agents’ names are the options. Add or remove a connection to change this list.")
                .font(.caption).foregroundStyle(.secondary)
            if let confidence = decision.minConfidence {
                Text("Imported native-confidence fallback: below \(percent(confidence))%.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
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
        Section("Destinations — lowest to highest") {
            ForEach(Array(decision.options.enumerated()), id: \.element.id) { index, option in
                scoreRow(option, index: index)
            }
            Text("Move levels up or down, or drag them to reorder. Scores route to the nearest level; ties go higher.")
                .font(.caption).foregroundStyle(.secondary)
            Text("The original fractional score is retained in the result.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func scoreRow(_ option: CoreWorkflowType.DecisionOption, index: Int) -> some View {
        let edge = edges.first { $0.output == option.id }
        let name = WorkflowDecisionLabels.scoreLevelName(option, edge: edge, definition: model.definition)
        return HStack {
            Text("\(index)").monospacedDigit().foregroundStyle(.secondary).frame(width: 20)
            Text(name).frame(maxWidth: .infinity, alignment: .leading)
            Button {
                model.moveDecisionLevel(id, option: option.id, to: index - 1)
            } label: {
                Image(systemName: "chevron.up").frame(width: 28, height: 28).contentShape(.rect)
            }.disabled(index == 0).accessibilityLabel("Move \(name) up")
                .accessibilityIdentifier("decisionLevelUp-\(option.id)")
            Button {
                model.moveDecisionLevel(id, option: option.id, to: index + 1)
            } label: {
                Image(systemName: "chevron.down").frame(width: 28, height: 28).contentShape(.rect)
            }.disabled(index == decision.options.count - 1).accessibilityLabel("Move \(name) down")
                .accessibilityIdentifier("decisionLevelDown-\(option.id)")
        }
        .buttonStyle(.borderless).contentShape(.rect)
        .accessibilityIdentifier("decisionLevel-\(option.id)")
        .draggable(option.id)
        .dropDestination(for: String.self) { options, _ in
            guard let option = options.first, decision.options.contains(where: { $0.id == option }) else {
                return false
            }
            model.moveDecisionLevel(id, option: option, to: index)
            return true
        }
    }

    private func percent(_ value: Int) -> String {
        (Double(value) / 100).formatted(.number.precision(.fractionLength(0...2)))
    }
}
