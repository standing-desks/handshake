import Foundation

nonisolated enum BrowserAddress {
    static let invalidMessage = "Enter a valid website address, such as example.com or http://localhost:3000."

    static func parse(_ input: String) -> URL? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        if value.lowercased() == "about:blank" { return URL(string: "about:blank") }
        let lower = value.lowercased()
        let reserved = ["javascript:", "file:", "mailto:", "data:", "blob:", "about:", "ftp:"]
        if reserved.contains(where: { lower.hasPrefix($0) }) { return nil }
        let explicit = lower.hasPrefix("http:") || lower.hasPrefix("https:")
        if !explicit, let colon = value.firstIndex(of: ":"), !value.hasPrefix("[") {
            let prefix = String(value[..<colon])
            let rest = value[value.index(after: colon)...]
            // A host:port is an address; every other explicit scheme is rejected before inference.
            let isScheme = prefix.range(of: #"^[a-zA-Z][a-zA-Z0-9+.-]*$"#, options: .regularExpression) != nil
            if !prefix.contains("."), isScheme, rest.first?.isNumber != true { return nil }
        }
        guard !value.hasPrefix("/"), !value.contains("\\"),
            var components = URLComponents(string: explicit ? value : "https://" + value),
            let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
            ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
            components.port.map({ (1...65535).contains($0) }) ?? true
        else { return nil }
        if !explicit, ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host.lowercased()) {
            components.scheme = "http"
        }
        return components.url
    }
}
