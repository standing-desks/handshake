import SwiftUI

/// Decision settings use the graph's existing grouped popover. Core validates and executes them.
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

    var body: some View {
        VStack(spacing: 0) {
            Picker("Settings", selection: $defaults) {
                Text("Decision").tag(false)
                Text("Launch defaults").tag(true)
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 8)
            if defaults {
                Form {
                    LabeledContent("Harness", value: "Nouli")
                    TextField("Provider profile", text: optional(decision.provider))
                    TextField("Model", text: optional(decision.model))
                    Text(
                        "Leave empty to use Nouli’s defaults. Edit these before starting the workflow."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }.formStyle(.grouped)
            } else {
                Form {
                    Section {
                        TextField("Name", text: model.roleBinding(role).name).textFieldStyle(.plain)
                        WorkflowAgentColorPicker(color: model.roleBinding(role).color)
                    }
                    Section("Question") {
                        Picker("Answer type", selection: decision.kind) {
                            ForEach(CoreWorkflowType.DecisionKind.allCases, id: \.self) { Text($0.title).tag($0) }
                        }.onChange(of: decision.wrappedValue.kind) { _, _ in model.resetDecisionOutputs(role.id) }
                        TextEditor(text: decision.question).font(.body).frame(height: 80)
                            .scrollContentBackground(.hidden).accessibilityLabel("Decision question")
                        Text("Ask one focused question about the incoming evidence.").font(.caption).foregroundStyle(
                            .secondary)
                    }
                    outputSettings
                    Section("Inputs") {
                        Toggle("Include the workflow task", isOn: decision.includeTask)
                        Text("Receives the selected incoming work, including typed outcomes from earlier decisions.")
                            .font(.caption).foregroundStyle(.secondary)
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
                    Text("Refusal, unavailable gated confidence, and provider failure pause for an explicit retry.")
                        .font(.caption).foregroundStyle(.secondary)
                }.formStyle(.grouped).scrollContentBackground(.hidden)
            }
            Divider()
            HStack {
                Menu("Actions") {
                    WorkflowGraphConnectionMenu(model: model, source: role.id)
                    Button("Delete decision", role: .destructive) {
                        close()
                        model.removeGraphRole(role.id)
                    }
                }.menuStyle(.borderlessButton).fixedSize()
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }.padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: min(420, maximum.width), height: min(defaults ? 300 : 640, maximum.height))
        .accessibilityIdentifier("decisionSettings")
        .onChange(of: decision.wrappedValue.outputs) { _, _ in model.reconcileDecisionOutputs(role.id) }
    }

    private var outputSettings: some View {
        Section(decision.wrappedValue.kind == .score ? "Levels and outputs" : "Outputs") {
            if decision.wrappedValue.kind == .noul {
                Stepper(
                    "Yes at or above: \(decision.wrappedValue.trueThreshold / 100)%", value: decision.trueThreshold,
                    in: 0...10_000, step: 100)
                Stepper(
                    "No at or below: \(decision.wrappedValue.falseThreshold / 100)%", value: decision.falseThreshold,
                    in: 0...10_000, step: 100)
                Text("A gap creates an Uncertain output. Equal thresholds route the exact boundary to Yes.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(decision.options) { option in
                    DisclosureGroup(option.wrappedValue.name) {
                        TextField("Name", text: option.name)
                        TextField("Description", text: option.description, axis: .vertical)
                        if decision.wrappedValue.options.count > 2 {
                            Button("Remove output", role: .destructive) {
                                let id = option.wrappedValue.id
                                decision.wrappedValue.options.removeAll { $0.id == id }
                                model.removeDecisionLinks(role.id, output: id)
                            }
                        }
                    }
                }
                Button("Add output", systemImage: "plus") {
                    decision.wrappedValue.options.append(
                        .init(id: UUID().uuidString, name: "New output", description: ""))
                }.disabled(decision.wrappedValue.options.count >= (decision.wrappedValue.kind == .score ? 10 : 255))
                if decision.wrappedValue.kind == .score {
                    Text(
                        "Levels start at zero, lowest first. Route to the nearest level, with ties going higher. "
                            + "The original fractional score is preserved."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                } else {
                    Toggle(
                        "Send low-confidence answers to Fallback",
                        isOn: Binding(
                            get: { decision.wrappedValue.minConfidence != nil },
                            set: { decision.wrappedValue.minConfidence = $0 ? 6_000 : nil }))
                    if decision.wrappedValue.minConfidence != nil {
                        Stepper(
                            "Native confidence below: \((decision.wrappedValue.minConfidence ?? 0) / 100)%",
                            value: Binding(
                                get: { decision.wrappedValue.minConfidence ?? 6_000 },
                                set: { decision.wrappedValue.minConfidence = $0 }), in: 0...10_000, step: 100)
                        Text(
                            "Validate the threshold for this task. Missing native confidence pauses the node."
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(decision.wrappedValue.outputs) { output in
                Picker(
                    output.name,
                    selection: Binding(
                        get: {
                            model.definition.graph?.edges.first { $0.from == role.id && $0.output == output.id }?.to
                                ?? ""
                        },
                        set: { model.connectDecision(role.id, output: output.id, to: $0) })
                ) {
                    Text("Choose receiving node").tag("")
                    ForEach(model.definition.roles.filter { $0.id != role.id }) { Text($0.name).tag($0.id) }
                }
            }
        }
    }

    private func optional(_ binding: Binding<String?>) -> Binding<String> {
        Binding(get: { binding.wrappedValue ?? "" }, set: { binding.wrappedValue = $0.isEmpty ? nil : $0 })
    }
}

extension WorkflowDesignerModel {
    func addDecision(at position: CoreWorkflowType.Position) -> String {
        let id = addGraphRole(at: position)
        if let index = definition.roles.firstIndex(where: { $0.id == id }) {
            definition.roles[index].name = "Decision"
            definition.roles[index].instructions = "Evaluate the incoming work with Nouli."
            definition.roles[index].color = nil
        }
        definition.graph?.decisions[id] = .init()
        return id
    }

    func reconcileDecisionOutputs(_ id: String) {
        let outputs = Set(definition.graph?.decisions[id]?.outputs.map(\.id) ?? [])
        definition.graph?.edges.removeAll { $0.from == id && !outputs.contains($0.output ?? "") }
    }

    func resetDecisionOutputs(_ id: String) {
        definition.graph?.decisions[id]?.minConfidence = nil
        definition.graph?.edges.removeAll { $0.from == id }
    }

    func removeDecisionLinks(_ id: String, output: String) {
        definition.graph?.edges.removeAll { $0.from == id && $0.output == output }
    }

    func connectDecision(_ id: String, output: String, to destination: String) {
        removeDecisionLinks(id, output: output)
        guard !destination.isEmpty else { return }
        definition.graph?.edges.append(
            .init(id: UUID().uuidString, from: id, to: destination, event: .done, output: output))
    }

    func outputTitle(_ edge: CoreWorkflowType.Edge) -> String {
        guard let id = edge.output else { return edge.event.title }
        return definition.graph?.decisions[edge.from]?.outputs.first { $0.id == id }?.name ?? id
    }
}
