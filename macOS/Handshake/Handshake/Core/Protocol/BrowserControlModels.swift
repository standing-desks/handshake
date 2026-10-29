import Foundation

nonisolated struct BrowserJob: Decodable, Sendable {
    let id: String
    let session: String
    let tab: String
    let action: BrowserAction
}

nonisolated struct BrowserControlState: Decodable, Sendable {
    var jobs: [BrowserJob]?
    var owners: [String: String]?
    var active: [String]?
}

nonisolated struct BrowserHostCommand: Encodable, Sendable {
    let action: String
    var id: String?
    var session: String?
    var tab: String?
    var result: BrowserControlResult?
}

nonisolated struct BrowserControlResult: Encodable, Sendable {
    struct Failure: Encodable, Sendable {
        let code: String
        let message: String
    }
    let success: Bool
    enum CodingKeys: String, CodingKey {
        case success = "ok"
        case tab, content, png, error
    }
    var tab: String?
    var content: String?
    var png: String?
    var error: Failure?
}

nonisolated struct BrowserAction: Decodable, Sendable {
    let action: String
    var url: String?
    var element: String?
    var text: String?
    var key: String?
    var value: String?
    var state: String?
    var deltaY: Int?
    enum CodingKeys: String, CodingKey {
        case action, url, element, text, key, value, state
        case deltaY = "dy"
    }
}
