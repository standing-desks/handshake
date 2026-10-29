import Foundation
import Observation

/// The designer's transient conversation and proposed revision. Core owns generation and validation.
@Observable
final class WorkflowAssistantModel {
    var choice = HarnessChoice(harness: .codex)
    var input = ""
    private(set) var messages: [WorkflowChatMessage] = []
    private(set) var draft: WorkflowDraft?
    private(set) var failure: String?
    private(set) var generationID: String?
    private(set) var baseline: CoreWorkflowType.Definition?
    private var task: Task<Void, Never>?

    var isGenerating: Bool { generationID != nil }
    var canSend: Bool { !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isGenerating }

    func send(definition: CoreWorkflowType.Definition, using client: CoreClient) {
        guard canSend else { return }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        input = ""
        messages.append(.init(role: "user", text: text))
        request(definition: definition, using: client)
    }

    func retry(definition: CoreWorkflowType.Definition, using client: CoreClient) {
        guard !isGenerating, !messages.isEmpty else { return }
        request(definition: definition, using: client)
    }

    private func request(definition: CoreWorkflowType.Definition, using client: CoreClient) {
        let id = UUID().uuidString
        generationID = id
        baseline = definition
        failure = nil
        draft = nil
        task = Task {
            defer { if generationID == id { generationID = nil } }
            do {
                let result = try await client.sendAndAwaitCompletion(
                    .generateWorkflowType(generationID: id, choice: choice, messages: messages, definition: definition))
                guard generationID == id, !Task.isCancelled else { return }
                guard case .workflowDrafted(let proposed, let error) = result else {
                    throw CoreFailure.unexpectedCommandResult
                }
                if let error {
                    failure = error
                    messages.append(.init(role: "assistant", text: "Generation failed: \(error)"))
                } else if let proposed {
                    messages.append(.init(role: "assistant", text: proposed.message))
                    draft = proposed
                }
            } catch {
                guard generationID == id, !Task.isCancelled else { return }
                failure = error.localizedDescription
            }
        }
    }

    func stop(using client: CoreClient) {
        guard let id = generationID else { return }
        generationID = nil
        task?.cancel()
        task = nil
        Task { _ = try? await client.send(.cancelWorkflowGeneration(generationID: id)) }
    }

    func applied() { draft = nil }
}
