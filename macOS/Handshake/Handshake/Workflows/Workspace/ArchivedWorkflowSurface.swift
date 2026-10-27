import SwiftUI

/// Reopened tabs show recorded invocations. Starting or resuming work is always a user action.
struct ArchivedWorkflowSurface: View {
    let workflow: CoreWorkflow
    let startNewTerminal: () -> Void
    @State private var target: TraceTerminalTarget?

    private var history: [CoreWorkflowTerminal] { workflow.terminalHistory ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Saved history · Processes stopped", systemImage: "clock.arrow.circlepath")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if workflow.kind == .singleAgent { ResumeAgentButton(workflow: workflow) }
                Button("New Terminal", action: startNewTerminal)
                    .accessibilityIdentifier("restartClosedTerminal")
                Menu("Saved Output") {
                    ForEach(Array(history.enumerated()), id: \.element.terminalID) { invocation in
                        let (index, entry) = invocation
                        Button("\(title(entry)) · \(index + 1)") { show(entry) }
                    }
                }
                .disabled(workflow.terminalHistory?.isEmpty != false)
            }
            .padding(10)
            if let target {
                TerminalHistorySurface(target: target, returnToLive: {}, showsReturnToLive: false).id(target.id)
            } else {
                ContentUnavailableView(
                    "No Saved Output", systemImage: "clock",
                    description: Text("This tab has no retained terminal output. Start a new terminal to continue."))
            }
        }
        .background(.windowBackground)
        .task(id: workflow.id) { if let entry = workflow.terminalHistory?.last { show(entry) } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reopenedWorkflowHistory")
    }

    private func title(_ entry: CoreWorkflowTerminal) -> String {
        workflow.agents.first { $0.id == entry.agentID }?.role ?? workflow.customName ?? workflow.name
    }

    private func show(_ entry: CoreWorkflowTerminal) {
        target = TraceTerminalTarget(
            workflowID: workflow.id, agentID: entry.agentID,
            anchor: .init(terminalID: entry.terminalID, byteOffset: 0),
            timestamp: 0, message: title(entry), readToCurrentEnd: true)
    }
}
