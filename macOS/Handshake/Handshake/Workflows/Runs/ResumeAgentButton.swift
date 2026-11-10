import SwiftUI

/// Older tabs and harnesses without session hooks can still resume a conversation by its ID.
struct ResumeAgentButton: View {
    @Environment(CoreClient.self) private var client
    let workflow: CoreWorkflow
    var agentID: UInt64?
    @State private var isPresented = false
    @State private var session = ""
    @State private var isResuming = false
    @State private var failure: String?

    private var usesFile: Bool { workflow.harness == .piAgent || workflow.harness == .omp }

    var body: some View {
        Button("Resume agent…", systemImage: "arrow.clockwise") { isPresented = true }
            .accessibilityIdentifier("resumeAgentSession")
            .sheet(isPresented: $isPresented) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Resume \(workflow.name)").font(.headline)
                    Text(
                        usesFile
                            ? "Leave blank to resume the recorded conversation, or enter its exact session file path."
                            : "Leave blank to resume the recorded conversation, or enter its exact session ID."
                    )
                    .foregroundStyle(.secondary)
                    TextField(usesFile ? "Session file path" : "Session ID", text: $session)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("resumeSessionID")
                    if let failure { Text(failure).foregroundStyle(.red).font(.caption) }
                    HStack {
                        Spacer()
                        Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
                            .disabled(isResuming)
                        Button(isResuming ? "Resuming…" : "Resume") { isResuming = true }
                            .keyboardShortcut(.defaultAction)
                            .disabled(isResuming)
                    }
                }
                .padding(24).frame(width: 420)
                .interactiveDismissDisabled(isResuming)
                .task(id: isResuming) {
                    guard isResuming else { return }
                    do {
                        let receipt = try await client.send(
                            .recoverAgent(workflowID: workflow.id, agentID: agentID, session: session, shellOnly: false)
                        )
                        if let error = receipt.error {
                            throw CoreFailure.commandRejected(code: error.code, message: error.message)
                        }
                        isPresented = false
                    } catch { failure = error.localizedDescription }
                    isResuming = false
                }
                .appZoom()
            }
    }
}

#Preview {
    ResumeAgentButton(
        workflow: .init(
            workflowID: 1, sessionID: 1, name: "Codex", kind: .singleAgent, harness: .codex,
            terminalID: 1, status: .interrupted, startedAt: 0, endedAt: 1, restored: true)
    )
    .environment(CoreClient(transport: CoreWorker(dataDirectory: AppPaths.previewDirectory)))
    .padding()
}
