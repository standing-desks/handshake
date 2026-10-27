import Foundation

nonisolated enum FeatureFlagID: String, Codable, Identifiable, Sendable {
    case tabManagement
    case crossAgentMemoryConsolidation
    var id: Self { self }
}

nonisolated struct CoreFeatureConfiguration: Decodable, Equatable, Sendable {
    let tabManagement: Bool
    let crossAgentMemoryConsolidation: Bool
    init(crossAgentMemoryConsolidation: Bool = false, tabManagement: Bool = false) {
        self.tabManagement = tabManagement
        self.crossAgentMemoryConsolidation = crossAgentMemoryConsolidation
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        crossAgentMemoryConsolidation =
            try values.decodeIfPresent(Bool.self, forKey: .crossAgentMemoryConsolidation) ?? false
        tabManagement = try values.decodeIfPresent(Bool.self, forKey: .tabManagement) ?? false
    }
    private enum CodingKeys: String, CodingKey {
        case tabManagement = "tab_management"
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
