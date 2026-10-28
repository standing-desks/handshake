import Foundation

nonisolated enum HandshakeMemoryAction: Encodable, Sendable, Equatable {
    case status, sync
    case setEnabled(Bool)
    case withdraw(String)
    case readArchive(String)
    case restore(String)
    case correct(id: String, revision: String, text: String)

    private enum CodingKeys: String, CodingKey { case type, enabled, id, revision, text }
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
        case .readArchive(let id):
            try values.encode("readArchive", forKey: .type)
            try values.encode(id, forKey: .id)
        case .correct(let id, let revision, let text):
            try values.encode("correct", forKey: .type)
            try values.encode(id, forKey: .id)
            try values.encode(revision, forKey: .revision)
            try values.encode(text, forKey: .text)
        case .restore(let id):
            try values.encode("restore", forKey: .type)
            try values.encode(id, forKey: .id)
        }
    }
}

nonisolated struct HandshakeMemoryRequest: Encodable, Sendable {
    let dataDirectory: String
    let folder: String
    let action: HandshakeMemoryAction
}

nonisolated struct HandshakeMemorySnapshot: Decodable, Sendable {
    let enabled: Bool
    let folder: String
    let storePath: String
    let amisPath: String
    let claudePath: String
    let codexPath: String
    let records: [HandshakeMemorySummary]
    let status: String
    let message: String
    let lastSync: String?
    let modelCalls: UInt64
    var archivedRecords: [HandshakeMemorySummary]?
    var archiveDetail: HandshakeMemoryArchiveDetail?
}

nonisolated struct HandshakeMemoryArchiveDetail: Decodable, Identifiable, Sendable {
    let id: String
    let title: String
    let text: String
}

nonisolated struct HandshakeMemorySummary: Decodable, Identifiable, Sendable {
    let id: String
    let title: String
    let sources: Int
    let preview: String
    var revision: String?
}

nonisolated struct HandshakeMemoryResponse: Decodable, Sendable {
    let snapshot: HandshakeMemorySnapshot?
    let error: String?
}
