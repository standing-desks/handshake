import Foundation

nonisolated enum ExperimentalFeatureID: String, Codable, Identifiable, Sendable {
    case crossAgentMemoryConsolidation
    var id: Self { self }
}

nonisolated struct CoreExperimentalConfiguration: Decodable, Equatable, Sendable {
    let crossAgentMemoryConsolidation: Bool
    init(crossAgentMemoryConsolidation: Bool = false) {
        self.crossAgentMemoryConsolidation = crossAgentMemoryConsolidation
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        crossAgentMemoryConsolidation =
            try values.decodeIfPresent(Bool.self, forKey: .crossAgentMemoryConsolidation) ?? false
    }
    private enum CodingKeys: String, CodingKey {
        case crossAgentMemoryConsolidation = "cross_agent_memory_consolidation"
    }
}

nonisolated struct ExperimentalFeatureState: Decodable, Equatable, Identifiable, Sendable {
    let id: ExperimentalFeatureID
    let title: String
    let description: String
    let enabled: Bool
}

nonisolated struct ExperimentalSnapshot: Decodable, Sendable {
    let features: [ExperimentalFeatureState]
    let file: FilePreview
}

nonisolated struct ExperimentalRequest: Encodable, Sendable {
    let type: String
    var id: ExperimentalFeatureID?
    var enabled: Bool?
    var expectedVersion: FileVersion?
}

nonisolated struct ExperimentalResponse: Decodable, Sendable {
    let snapshot: ExperimentalSnapshot?
    let result: FileSaveResult?
    let error: String?
}
