import SwiftUI

struct WorkflowGraphAgentPopover: View {
    @Environment(\.effectiveReduceMotion) private var reduceMotion
    @Bindable var model: WorkflowDesignerModel
    let role: CoreWorkflowType.Role
    let close: () -> Void
    @FocusState private var panelFocused: Bool
    @Environment(\.appZoomMaximumPresentationSize) private var maximumSize
    @State private var advanced = false

    var body: some View {
        VStack(spacing: 0) {
            WorkflowNodeKindPicker(model: model, id: role.id)
            agentSettings
            Divider()
            HStack {
                Menu("Actions") {
                    WorkflowGraphConnectionMenu(model: model, source: role.id, connected: close)
                    Divider()
                    Button("Delete agent", role: .destructive, action: deleteAgent)
                }.menuStyle(.borderlessButton).fixedSize()
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }.padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: min(420, maximumSize.width), height: min(advanced ? 700 : 550, maximumSize.height))
        .animation(reduceMotion ? nil : Motion.disclosure, value: advanced)
        .focusable(interactions: .edit)
        .focused($panelFocused)
        .focusEffectDisabled()
        .onDeleteCommand { if panelFocused { deleteAgent() } }
        .onAppear { panelFocused = true }
    }

    private func deleteAgent() {
        close()
        model.removeGraphRole(role.id)
    }

    private var agentSettings: some View {
        let binding = model.roleBinding(role)
        return Form {
            Section {
                WorkflowNodeIdentityFields(role: binding)
            }
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    TextEditor(text: binding.instructions).font(.body).frame(height: 120)
                        .scrollContentBackground(.hidden)
                        .accessibilityLabel("Instructions").accessibilityIdentifier("graphAgentInstructions")
                    Text("Used for every task this agent receives.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Instructions")
            }
            if inputCount > 1 { incomingWorkSettings }
            completionSettings
            Section {
                DisclosureGroup("Advanced", isExpanded: $advanced) {
                    WorkflowAgentDefaultsEditor(role: binding)
                }.accessibilityIdentifier("agentAdvanced")
            }
        }.formStyle(.grouped).scrollContentBackground(.hidden)
    }

    private var inputLinks: [CoreWorkflowType.Edge] {
        model.definition.graph?.agentEdges.filter { $0.to == role.id && $0.event != .feedback } ?? []
    }

    private var inputCount: Int { inputLinks.count }

    private var hasReviewLinks: Bool {
        model.definition.graph?.agentEdges.contains {
            $0.from == role.id && ($0.event == .feedback || $0.event == .approved)
        } == true
    }

    private var incomingWorkSettings: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Picker(
                    "Incoming work",
                    selection: Binding(
                        get: { model.definition.graph?.receive[role.id] ?? .any },
                        set: { model.definition.graph?.receive[role.id] = $0 })
                ) {
                    Text("Start as work arrives").tag(CoreWorkflowType.Receive.any)
                    Text("Wait for every incoming link").tag(CoreWorkflowType.Receive.all)
                }.pickerStyle(.radioGroup).labelsHidden().accessibilityIdentifier("graphReceive")
                Text(
                    model.definition.graph?.receive[role.id] == .all
                        ? "Wait for one item from every incoming link. Review feedback can start this agent sooner."
                        : "Start for each incoming item. If the agent is busy, new items wait."
                ).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(.vertical, 4)
        } header: {
            Text("Incoming work")
        }
    }

    private var completionSettings: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Picker(
                    "When work ends",
                    selection: Binding(
                        get: { model.definition.graph?.reviewsWork(role.id) == true },
                        set: { model.setGraphReview(role.id, enabled: $0) })
                ) {
                    Text("Send the final result").tag(false).disabled(hasReviewLinks)
                    Text("Approve or request changes").tag(true)
                }.pickerStyle(.radioGroup).labelsHidden().accessibilityIdentifier("graphCompletionRule")
                Text(completionHelp).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.padding(.vertical, 4)
        } header: {
            Text("When work ends")
        }
    }

    private var completionHelp: String {
        let graph = model.definition.graph
        guard graph?.reviewsWork(role.id) == true else {
            return graph?.returnsResult(role.id) == true
                ? "Return the final result to the workflow."
                : "Send the final result through Work complete links."
        }
        if hasReviewLinks {
            return "Approve work or request changes. Approved and Changes requested links send the result. "
                + "Delete those links to use Send the final result."
        }
        return graph?.returnsResult(role.id) == true
            ? "Approve the work to return the final result. Add a Changes requested link to send feedback."
            : "Approve work or request changes. Add links for Approved or Changes requested to send the result."
    }

}

private struct WorkflowDisclosureStyle: DisclosureGroupStyle {
    @Environment(\.effectiveReduceMotion) private var reduceMotion
    let identifier: String

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(reduceMotion ? nil : Motion.disclosure) { configuration.isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                    configuration.label
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, minHeight: 24, alignment: .leading).contentShape(.rect)
            }.buttonStyle(.plain)
                .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
                .accessibilityIdentifier(identifier)
            if configuration.isExpanded { configuration.content }
        }
    }
}

struct WorkflowLinkPopover: View {
    @Bindable var model: WorkflowDesignerModel
    let edge: CoreWorkflowType.Edge
    let close: () -> Void

    private var events: [CoreWorkflowType.GraphEvent] {
        let events: [CoreWorkflowType.GraphEvent] = [.done, .pieceReady, .feedback, .approved]
        return events.filter { $0 != .done || model.definition.graph?.reviewsWork(edge.from) != true }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(name(edge.from)) → \(name(edge.to))").font(.headline)
            if let decision = model.definition.graph?.decisions[edge.from] {
                if model.definition.graph?.agentEdges.filter({ $0.from == edge.from }).count == 1 {
                    Text("Passthrough: forward inputs directly.").font(.caption).foregroundStyle(.secondary)
                } else if decision.kind == .choice && decision.minConfidence == nil {
                    Text("Nouli option: \(name(edge.to))").font(.caption).foregroundStyle(.secondary)
                } else if decision.kind == .noul {
                    Picker(
                        "Answer",
                        selection: Binding(
                            get: { model.definition.graph?.edges.first { $0.id == edge.id }?.output ?? "" },
                            set: { model.assignDecisionOutput(edge.from, edge: edge.id, output: $0) })
                    ) {
                        Text("Unassigned").tag("").disabled(true)
                        ForEach(decision.outputs) { Text($0.name).tag($0.id) }
                    }
                } else {
                    Text(model.outputTitle(edge)).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Picker(
                    "Send work when",
                    selection: Binding(
                        get: { model.definition.graph?.edges.first { $0.id == edge.id }?.event ?? edge.event },
                        set: { value in
                            guard let index = model.definition.graph?.edges.firstIndex(where: { $0.id == edge.id })
                            else {
                                return
                            }
                            model.definition.graph?.edges[index].event = value
                            if value == .feedback || value == .approved {
                                model.setGraphReview(edge.from, enabled: true)
                            }
                        })
                ) {
                    ForEach(events, id: \.self) { event in
                        Text(event.title).tag(event).disabled(
                            model.definition.graph?.edges.contains {
                                $0.id != edge.id && $0.from == edge.from && $0.to == edge.to && $0.event == event
                            } == true)
                    }
                }
                .accessibilityIdentifier("graphLinkEvent")
                Text(eventDescription).font(.caption).foregroundStyle(.secondary)
                Menu("Add another event") {
                    ForEach(
                        events.filter { event in
                            model.definition.graph?.edges.contains {
                                $0.from == edge.from && $0.to == edge.to && $0.event == event
                            } != true
                        }, id: \.self
                    ) { event in
                        Button(event.title) { model.connect(from: edge.from, to: edge.to, event: event) }
                    }
                }.disabled(
                    events.allSatisfy { event in
                        model.definition.graph?.edges.contains {
                            $0.from == edge.from && $0.to == edge.to && $0.event == event
                        } == true
                    })
            }
            HStack {
                Button("Delete link", role: .destructive) {
                    close()
                    model.removeGraphEdge(edge.id)
                }
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
        }.padding(16).frame(width: 300)
    }

    private var eventDescription: String {
        switch model.definition.graph?.edges.first(where: { $0.id == edge.id })?.event ?? edge.event {
        case .task: "Send the same user task to this agent."
        case .done: "Send the final result when the source completes its work."
        case .pieceReady: "Send an item while the source keeps working."
        case .feedback: "End this review and send the changes to the receiving agent."
        case .approved: "End this review and send the accepted result to the receiving agent."
        }
    }

    private func name(_ id: String) -> String { model.definition.roles.first { $0.id == id }?.name ?? id.capitalized }
}

struct WorkflowGraphSettingsPopover: View {
    @Bindable var model: WorkflowDesignerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Workflow settings").font(.headline)
            Picker(
                "Completion",
                selection: Binding(
                    get: { model.definition.graph?.finish ?? .all }, set: { model.definition.graph?.finish = $0 })
            ) {
                Text("Wait for all results").tag(CoreWorkflowType.Finish.all)
                Text("Choose a result").tag(CoreWorkflowType.Finish.choose)
                Text("Compare times").tag(CoreWorkflowType.Finish.timed)
            }
            Text(completionDescription).font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Advanced") {
                VStack(alignment: .leading, spacing: 8) {
                    Stepper(
                        "Activation limit: \(model.definition.graph?.maxActivations ?? 32)",
                        value: Binding(
                            get: { model.definition.graph?.maxActivations ?? 32 },
                            set: { model.definition.graph?.maxActivations = $0 }), in: 1...256)
                    Text("Stop feedback loops and repeated work after this many activations.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.disclosureGroupStyle(WorkflowDisclosureStyle(identifier: "graphAdvanced"))
        }.padding(16).frame(width: 320)
    }

    private var completionDescription: String {
        switch model.definition.graph?.finish ?? .all {
        case .all: "Agents with no forward outputs return results. Wait for all results and active work to stop."
        case .choose: "Keep all results. Select one after active work stops."
        case .timed: "Compare each agent's time from task delivery to completion."
        }
    }
}
