import SwiftUI

struct WorkflowAssistantView: View {
    @Environment(CoreClient.self) private var client
    @Environment(HarnessModelCatalog.self) private var catalog
    @Bindable var assistant: WorkflowAssistantModel
    let definition: CoreWorkflowType.Definition
    let apply: (WorkflowDraft) -> Void
    let close: () -> Void

    private var available: [CoreHarness] {
        catalog.availableHarnesses(folder: client.snapshot?.folders.openFolder)
            .filter { [.codex, .claudeCode, .kiro].contains($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if assistant.messages.isEmpty {
                            Text("Describe how your agents should work together.").font(.headline)
                            Text(
                                "For example: route bugs to a debugger and features to an implementer."
                            )
                            .font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(Array(assistant.messages.enumerated()), id: \.offset) { _, message in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(message.role == "user" ? "You" : "Workflow assistant")
                                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                Text(message.text).textSelection(.enabled).font(.callout)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if assistant.isGenerating { ProgressView("Creating a draft…").controlSize(.small) }
                        if let failure = assistant.failure {
                            Text(failure).font(.callout).foregroundStyle(Color.statusNeedsAttention)
                            Button("Retry") { assistant.retry(definition: definition, using: client) }
                                .accessibilityIdentifier("workflowAssistantRetry")
                        }
                        if let draft = assistant.draft, draft.definition != nil {
                            draftCard(draft)
                        }
                        Color.clear.frame(height: 1).id("latest")
                    }.padding(14)
                }
                .onChange(of: assistant.messages.count) { _, _ in proxy.scrollTo("latest", anchor: .bottom) }
                .onChange(of: assistant.isGenerating) { _, _ in proxy.scrollTo("latest", anchor: .bottom) }
            }
            Divider()
            composer
        }
        .frame(minWidth: 260, idealWidth: 310, maxWidth: 380)
        .background(.bar)
        .accessibilityElement(children: .contain).accessibilityIdentifier("workflowAssistant")
        .task { await catalog.load(using: client) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Workflow assistant").font(.headline)
                Text("Beta").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(action: close) {
                    Label("Hide assistant", systemImage: "sidebar.left").labelStyle(.iconOnly)
                        .frame(minWidth: 28, minHeight: 28).contentShape(.rect)
                }
                .accessibilityIdentifier("workflowAssistantHide")
            }
            HarnessChoiceRow(
                title: "Assistant", symbol: "bubble.left", color: .secondary, choice: $assistant.choice,
                identifier: "workflowAssistant", allowedHarnesses: [.codex, .claudeCode, .kiro],
                showsPermissions: false, showsEffort: false
            )
            .disabled(assistant.isGenerating)
            Text("These choices write the draft. Set each workflow agent’s defaults on its card.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(14)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $assistant.input).font(.callout).frame(minHeight: 60, maxHeight: 100)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator))
                .accessibilityLabel("Describe your workflow").accessibilityIdentifier("workflowAssistantInput")
            HStack {
                Text("Review a draft before applying it.").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if assistant.isGenerating {
                    Button("Stop") { assistant.stop(using: client) }.accessibilityIdentifier("workflowAssistantStop")
                } else {
                    Button("Send") { assistant.send(definition: definition, using: client) }
                        .buttonStyle(.borderedProminent).disabled(!assistant.canSend || available.isEmpty)
                        .accessibilityIdentifier("workflowAssistantSend")
                }
            }
        }.padding(12)
    }

    private func draftCard(_ draft: WorkflowDraft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(draft.definition?.name ?? "Workflow draft", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.callout.weight(.semibold))
            Text("Validated workflow definition").font(.caption).foregroundStyle(.secondary)
            if assistant.baseline != definition {
                Text("The canvas changed. Send another message to update the draft before applying it.")
                    .font(.caption).foregroundStyle(Color.statusNeedsAttention)
            }
            Button("Apply revision") {
                apply(draft)
                assistant.applied()
            }
            .buttonStyle(.borderedProminent).disabled(assistant.baseline != definition)
            .accessibilityIdentifier("workflowAssistantApply")
            DisclosureGroup("TOML") {
                Text(draft.toml ?? "").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Text("Handshake adds file identity and version on Save.").font(.caption2).foregroundStyle(.secondary)
            }.disclosureGroupStyle(WorkflowDisclosureStyle(identifier: "workflowAssistantTOML"))
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
    }
}
