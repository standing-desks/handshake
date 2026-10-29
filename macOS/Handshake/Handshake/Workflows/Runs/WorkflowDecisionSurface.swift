import SwiftUI

/// A Nouli agent exposes typed outcomes without pretending to have an interactive terminal.
struct WorkflowDecisionSurface: View {
    @Environment(CoreClient.self) private var client
    let workflowID: UInt64
    let agent: CoreAgent
    let run: CoreWorkflowRun
    @State private var task = ""
    @State private var failure: String?
    @State private var submitting = false

    private var key: String { String(agent.id) }
    private var role: String? { run.agents.first { $0.id == agent.id }?.role }
    private var node: CoreWorkflowType.DecisionNode? {
        role.flatMap { run.workflowType?.definition.graph?.decisions[$0] }
    }

    private var passthroughDestination: String? {
        let graph = run.workflowType?.definition.graph
        let edges = graph?.agentEdges.filter { $0.from == role } ?? []
        guard edges.count == 1 else { return nil }
        return run.workflowType?.definition.roles.first { $0.id == edges[0].to }?.name ?? edges[0].to
    }

    private var isCompleted: Bool { run.agents.first { $0.id == agent.id }?.status == .completed }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label(agent.role, systemImage: "arrow.triangle.branch").font(.headline)
                Text(passthroughDestination != nil ? "Passthrough" : "Nouli · \(node?.kind.title ?? "Decision")")
                    .font(.caption).foregroundStyle(.secondary)
                if let node, passthroughDestination == nil { Text(node.question).textSelection(.enabled) }
                if run.needsTask && run.status == .running {
                    TextEditor(text: $task).frame(minHeight: 100).font(.body).accessibilityLabel("Workflow task")
                    Button("Start workflow") {
                        perform {
                            try await client.submitWorkflowTask(
                                workflowID: workflowID, generation: run.generation, prompt: task)
                        }
                    }
                    .buttonStyle(.borderedProminent).disabled(
                        task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || submitting)
                } else if let error = run.decisionErrors[key] {
                    Text(error).foregroundStyle(Color.statusNeedsAttention).textSelection(.enabled)
                    Button("Retry captured decision") {
                        perform { try await client.retryDecision(workflowID: workflowID, generation: run.generation) }
                    }
                    .disabled(submitting)
                    Text("Retry uses the captured inputs and configured model. Earlier attempts remain in Traces.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let destination = passthroughDestination, isCompleted {
                    Label(
                        "Inputs passed through to \(destination).",
                        systemImage: "arrow.right")
                } else if let output = run.decisionOutputs[key] {
                    let name = node?.outputs.first { $0.id == output }?.name ?? output
                    Label("Selected output: \(name)", systemImage: "arrow.right.circle")
                } else {
                    Text(
                        run.agents.first { $0.id == agent.id }?.status == .running
                            ? "Evaluating captured inputs…" : "Waiting for a selected incoming route."
                    )
                    .foregroundStyle(.secondary)
                }
                if let value = run.decisionResults[key] { jsonDisclosure("Typed result", value: value) }
                if let value = run.decisionInputs[key] { jsonDisclosure("Captured inputs", value: value) }
                if let failure { Text(failure).foregroundStyle(Color.statusNeedsAttention) }
            }.padding(24).frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity)
        }.background(.windowBackground)
    }

    private func jsonDisclosure(_ title: String, value: String) -> some View {
        DisclosureGroup(title) {
            Text(value).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func perform(_ action: @escaping () async throws -> Void) {
        submitting = true
        Task {
            defer { submitting = false }
            do {
                try await action()
                failure = nil
            } catch { failure = error.localizedDescription }
        }
    }
}
