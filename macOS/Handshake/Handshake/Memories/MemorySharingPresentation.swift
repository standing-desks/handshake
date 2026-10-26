import Foundation

/// Presentation uses a collection so additional native profiles do not require a new layout.
nonisolated struct MemorySharingProfile: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let path: String

    static func names(_ profiles: [Self]) -> String {
        profiles.map(\.name).formatted(.list(type: .and))
    }
}

extension HandshakeMemorySnapshot {
    /// Compatibility mapping for the existing two-adapter wire contract; this adds no adapter support.
    nonisolated var sharingProfiles: [MemorySharingProfile] {
        [
            .init(id: "claude_code", name: "Claude Code", path: claudePath),
            .init(id: "codex", name: "Codex", path: codexPath),
        ]
    }

    nonisolated var sharingStatus: String {
        switch status {
        case "sharing": "Sharing automatically"
        case "paused": "Sharing paused"
        case "held": "Waiting to reconcile"
        default: "Starting automatic sharing"
        }
    }
}

extension HandshakeMemorySummary {
    /// Omit a duplicate opening Markdown heading in the preview, without changing source bytes.
    nonisolated var sharingPreview: String {
        var lines = preview.components(separatedBy: .newlines)
        guard let first = lines.first, first.hasPrefix("#") else { return preview }
        let heading = first.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
        guard heading == title else { return preview }
        lines.removeFirst()
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
