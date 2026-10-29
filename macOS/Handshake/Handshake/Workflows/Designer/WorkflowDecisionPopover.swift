import SwiftUI

/// The question and its destinations stay visible ahead of less common settings.
struct WorkflowDecisionPopover: View {
    @Bindable var model: WorkflowDesignerModel
    let role: CoreWorkflowType.Role
    let close: () -> Void
    @Environment(\.appZoomMaximumPresentationSize) private var maximum
    @Environment(\.effectiveReduceMotion) private var reduceMotion
    @State private var advanced = false
    @FocusState private var questionFocused: Bool

    private var decision: Binding<CoreWorkflowType.DecisionNode> {
        Binding(
            get: { model.definition.graph?.decisions[role.id] ?? .init() },
            set: {
                guard model.definition.graph?.decisions[role.id] != nil else { return }
                model.definition.graph?.decisions[role.id] = $0
            })
    }

    private var routes: [CoreWorkflowType.Edge] { model.decisionEdges(role.id) }
    private var preferredHeight: CGFloat {
        if advanced || model.usesAlwaysOutputs(role.id) { return 680 }
        if routes.count == 1 { return 310 }
        switch decision.wrappedValue.kind {
        case .choice: return min(630, 440 + CGFloat(routes.count) * 36)
        case .noul: return decision.wrappedValue.trueThreshold > decision.wrappedValue.falseThreshold ? 660 : 600
        case .score: return min(680, 460 + CGFloat(routes.count) * 40)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            WorkflowNodeKindPicker(model: model, id: role.id)
            ScrollViewReader { proxy in
                settings.task(id: model.decisionFocus?.id) {
                    guard let issue = model.decisionFocus, issue.nodeID == role.id else { return }
                    await Task.yield()
                    proxy.scrollTo(issue.field, anchor: .center)
                    questionFocused = issue.field == .question
                }
            }
            Divider()
            HStack {
                Menu("Actions") {
                    WorkflowGraphConnectionMenu(model: model, source: role.id, connected: close)
                    Button("Delete decision", role: .destructive) {
                        close()
                        model.removeGraphRole(role.id)
                    }
                }.menuStyle(.borderlessButton).fixedSize()
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }.padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: min(420, maximum.width), height: min(preferredHeight, maximum.height))
        .animation(reduceMotion ? nil : Motion.disclosure, value: advanced)
        .animation(reduceMotion ? nil : Motion.disclosure, value: routes.count == 1)
        .accessibilityElement(children: .contain).accessibilityIdentifier("decisionSettings")
    }

    private var settings: some View {
        Form {
            Section {
                WorkflowNodeIdentityFields(role: model.roleBinding(role))
                Picker(
                    "Answer type",
                    selection: Binding(
                        get: { decision.wrappedValue.kind },
                        set: { model.setDecisionKind(role.id, kind: $0) })
                ) {
                    ForEach(CoreWorkflowType.DecisionKind.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.menu).accessibilityIdentifier("decisionAnswerType")
            }
            if routes.count == 1 {
                Section("Passthrough") {
                    Text("Inputs go directly to \(model.nodeName(routes[0].to)).")
                    Text("No decision is made and Nouli is not called.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Section("Question") {
                    TextEditor(text: decision.question).font(.body).frame(height: 64).focused($questionFocused)
                        .scrollContentBackground(.hidden).accessibilityLabel("Decision question")
                        .accessibilityIdentifier("decisionQuestion")
                    if let issue = model.decisionValidation(role.id).first(where: { $0.field == .question }) {
                        WorkflowDecisionIssueLabel(issue: issue)
                    } else {
                        Text(questionHelp).font(.caption).foregroundStyle(.secondary)
                    }
                }.id(WorkflowDecisionIssue.Field.question)
                WorkflowDecisionAnswerSettings(model: model, id: role.id, decision: decision)
            }
            WorkflowDecisionAlwaysSettings(model: model, id: role.id)
            Section {
                DisclosureGroup("Advanced", isExpanded: $advanced) { advancedSettings }
                    .accessibilityIdentifier("decisionAdvanced")
            }
        }.formStyle(.grouped).scrollContentBackground(.hidden)
    }

    private var advancedSettings: some View {
        Group {
            Toggle("Include the workflow task", isOn: decision.includeTask).toggleStyle(.checkbox)
                .disabled(routes.count == 1)
            if model.definition.graph?.agentEdges.filter({ $0.to == role.id }).count ?? 0 > 1 {
                Picker(
                    "Incoming work",
                    selection: Binding(
                        get: { model.definition.graph?.receive[role.id] ?? .any },
                        set: { model.definition.graph?.receive[role.id] = $0 })
                ) {
                    Text("Start as work arrives").tag(CoreWorkflowType.Receive.any)
                    Text("Wait for every incoming link").tag(CoreWorkflowType.Receive.all)
                }
            }
            LabeledContent("Agent", value: "Nouli")
            TextField("Provider profile", text: optional(decision.provider))
            TextField("Model", text: optional(decision.model))
            Text("Empty fields use Nouli’s configured defaults. Incoming work is preserved through the selected route.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var questionHelp: String {
        switch decision.wrappedValue.kind {
        case .choice: "Choose which connected agent receives the incoming work."
        case .noul: "Ask a question that can be answered Yes or No."
        case .score: "Ask for a rating using the ordered scale below."
        }
    }

    private func optional(_ binding: Binding<String?>) -> Binding<String> {
        Binding(get: { binding.wrappedValue ?? "" }, set: { binding.wrappedValue = $0.isEmpty ? nil : $0 })
    }
}
