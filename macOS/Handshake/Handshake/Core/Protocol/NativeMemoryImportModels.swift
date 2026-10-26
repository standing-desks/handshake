import Foundation

nonisolated enum NativeMemoryImportAction: String, Encodable, Sendable {
    case status
    case importMemories = "import"
    case removeImported
}

nonisolated struct NativeMemoryImportRequest: Encodable, Sendable {
    let folder: String
    let action: NativeMemoryImportAction
}

nonisolated struct NativeMemoryImportSnapshot: Decodable, Sendable {
    let folder: String
    let claudePath: String
    let codexPath: String
    let sourceCount: Int
    let canImport: Bool
    let status: String
    let message: String
    let importID: String?

    enum CodingKeys: String, CodingKey {
        case folder, claudePath, codexPath, sourceCount, canImport, status, message
        case importID = "importId"
    }
}

nonisolated struct NativeMemoryImportResponse: Decodable, Sendable {
    let snapshot: NativeMemoryImportSnapshot?
    let error: String?
}
