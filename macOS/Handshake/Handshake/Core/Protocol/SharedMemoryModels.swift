import Foundation

nonisolated struct SharedMemoryAction: Encodable, Sendable {
    let operation: String
    var enabled: Bool?
    var text: String?
    var id: String?
    var sourceID: String?

    enum CodingKeys: String, CodingKey {
        case operation, enabled, text, id
        case sourceID = "source_id"
    }
}

nonisolated struct SharedMemoryRequest: Encodable, Sendable {
    let dataDirectory: String
    let folder: String
    let action: SharedMemoryAction
}

nonisolated struct SharedMemorySnapshot: Decodable, Sendable {
    let enabled: Bool
    let deliveryReady: Bool
    let folder: String
    let inbox: String
    let catalogPath: String
    let notes: [SharedMemoryNote]
    let diagnostics: [String]
    let detail: SharedMemoryDetail?
}

nonisolated struct SharedMemoryNote: Decodable, Sendable, Identifiable {
    let id: String
    let title: String
    let source: String
    let digest: String
    let status: String
}

nonisolated struct SharedMemoryDetail: Decodable, Sendable {
    let id: String
    let digest: String
    let text: String
}

nonisolated struct SharedMemoryResponse: Decodable, Sendable {
    let snapshot: SharedMemorySnapshot?
    let error: String?
}
