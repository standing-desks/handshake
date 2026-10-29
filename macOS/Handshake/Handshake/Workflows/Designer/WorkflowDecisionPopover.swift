import SwiftUI

/// The question is evaluated against options named after the connected agents.
struct WorkflowDecisionPopover: View {
    @Bindable var model: WorkflowDesignerModel
    let role: CoreWorkflowType.Role
    let close: () -> Void
    @Environment(\.appZoomMaximumPresentationSize) private var maximum
    @State private var defaults = false

    private var decision: Binding<CoreWorkflowType.DecisionNode> {
        Binding(
            get: { model.definition.graph?.decisions[role.id] ?? .init() },
            set: {
                guard model.definition.graph?.decisions[role.id] != nil else { return }
                model.definition.graph?.decisions[role.id] = $0
            })
    }

    private var routes: [CoreWorkflowType.Edge] {
        model.decisionEdges(role.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            WorkflowNodeKindPicker(model: model, id: role.id)
            Picker("Settings", selection: $defaults) {
                Text("Decision").tag(false)
                Text("Launch defaults").tag(true)
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 20).padding(.vertical, 8)
            if defaults {
                launchDefaults
            } else {
                settings
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
        .frame(width: min(420, maximum.width), height: min(defaults ? 350 : 640, maximum.height))
        .accessibilityIdentifier("decisionSettings")
    }

    private var settings: some View {
        Form {
            Section {
                TextField("Name", text: model.roleBinding(role).name).textFieldStyle(.plain)
                    .accessibilityIdentifier("graphAgentName")
                WorkflowAgentColorPicker(color: model.roleBinding(role).color)
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
                    TextEditor(text: decision.question).font(.body).frame(height: 80)
                        .scrollContentBackground(.hidden).accessibilityLabel("Decision question")
                        .accessibilityIdentifier("decisionQuestion")
                    Text(questionHelp).font(.caption).foregroundStyle(
                        .secondary)
                }
                WorkflowDecisionAnswerSettings(model: model, id: role.id, decision: decision)
            }
            Section("Inputs") {
                Toggle("Include the workflow task", isOn: decision.includeTask)
                    .disabled(routes.count == 1)
                Text("Incoming work is preserved through the selected route.").font(.caption).foregroundStyle(
                    .secondary)
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
            }
        }.formStyle(.grouped).scrollContentBackground(.hidden)
    }

    private var questionHelp: String {
        switch decision.wrappedValue.kind {
        case .choice: "Ask Nouli which connected agent should receive the work."
        case .noul: "Ask a question that can be answered Yes or No."
        case .score: "Ask for a rating using the ordered scale below."
        }
    }

    private var launchDefaults: some View {
        Form {
            LabeledContent("Harness", value: "Nouli")
            TextField("Provider profile", text: optional(decision.provider))
            TextField("Model", text: optional(decision.model))
            Text("Empty fields use Nouli’s configured defaults. Passthrough nodes do not use these settings.")
                .font(.caption).foregroundStyle(.secondary)
        }.formStyle(.grouped)
    }

    private func optional(_ binding: Binding<String?>) -> Binding<String> {
        Binding(get: { binding.wrappedValue ?? "" }, set: { binding.wrappedValue = $0.isEmpty ? nil : $0 })
    }
}
