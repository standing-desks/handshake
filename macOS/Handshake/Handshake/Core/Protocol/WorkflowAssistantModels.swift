import Foundation

nonisolated struct WorkflowChatMessage: Codable, Equatable, Sendable {
    let role: String
    let text: String
}

nonisolated struct WorkflowDraft: Codable, Equatable, Sendable {
    let message: String
    let definition: CoreWorkflowType.Definition?
    let toml: String?
}
