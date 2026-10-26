import Foundation

nonisolated enum FeatureFlagID: String, Codable, Identifiable, Sendable {
    case crossAgentMemoryConsolidation
    var id: Self { self }
}

nonisolated struct CoreFeatureConfiguration: Decodable, Equatable, Sendable {
    let crossAgentMemoryConsolidation: Bool
    init(crossAgentMemoryConsolidation: Bool = false) {
        self.crossAgentMemoryConsolidation = crossAgentMemoryConsolidation
    }
    private enum CodingKeys: String, CodingKey {
        case crossAgentMemoryConsolidation = "cross_agent_memory_consolidation"
    }
}

nonisolated struct FeatureFlagState: Decodable, Equatable, Identifiable, Sendable {
    let id: FeatureFlagID
    let title: String
    let description: String
    let enabled: Bool
}

nonisolated struct FeatureFlagSnapshot: Decodable, Sendable {
    let flags: [FeatureFlagState]
    let file: FilePreview
}

nonisolated struct FeatureFlagRequest: Encodable, Sendable {
    let type: String
    var id: FeatureFlagID?
    var enabled: Bool?
    var expectedVersion: FileVersion?
}

nonisolated struct FeatureFlagResponse: Decodable, Sendable {
    let snapshot: FeatureFlagSnapshot?
    let result: FileSaveResult?
    let error: String?
}
