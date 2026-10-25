import Foundation

nonisolated enum TwineMemoryAction: Encodable, Sendable, Equatable {
    case status, sync
    case setEnabled(Bool)
    case withdraw(String)

    private enum CodingKeys: String, CodingKey { case type, enabled, id }
    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .status: try values.encode("status", forKey: .type)
        case .sync: try values.encode("sync", forKey: .type)
        case .setEnabled(let enabled):
            try values.encode("setEnabled", forKey: .type)
            try values.encode(enabled, forKey: .enabled)
        case .withdraw(let id):
            try values.encode("withdraw", forKey: .type)
            try values.encode(id, forKey: .id)
        }
    }
}

nonisolated struct TwineMemoryRequest: Encodable, Sendable {
    let dataDirectory: String
    let folder: String
    let action: TwineMemoryAction
}

nonisolated struct TwineMemorySnapshot: Decodable, Sendable {
    let enabled: Bool
    let folder: String
    let storePath: String
    let amisPath: String
    let claudePath: String
    let codexPath: String
    let records: [TwineMemorySummary]
    let status: String
    let message: String
    let lastSync: String?
    let modelCalls: UInt64
}

nonisolated struct TwineMemorySummary: Decodable, Identifiable, Sendable {
    let id: String
    let title: String
    let sources: Int
    let preview: String
}

nonisolated struct TwineMemoryResponse: Decodable, Sendable {
    let snapshot: TwineMemorySnapshot?
    let error: String?
}
