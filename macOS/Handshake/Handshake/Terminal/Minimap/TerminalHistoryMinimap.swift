import AppKit

/// Sampling for the explicit saved-output text viewer, independent of live terminal indexing.
struct TerminalHistoryMinimap {
    struct Drawing {
        let columns: Int
        let rows: Int
        let strokes: [CGRect]
    }
    private var text = ""
    private var lines: [String] = []

    mutating func update(_ text: String) -> Drawing? {
        guard self.text != text else { return nil }
        self.text = text
        lines = text.components(separatedBy: "\n")
        let count = max(1, lines.count)
        let columns = max(1, lines.map(\.count).max() ?? 1)
        let strokes = stride(from: 0, to: count, by: max(1, count / 350)).compactMap { row -> CGRect? in
            let content = lines[row].trimmingCharacters(in: .whitespaces)
            guard !content.isEmpty else { return nil }
            return CGRect(
                x: 0.04, y: Double(row) / Double(count),
                width: Double(content.count) / Double(columns), height: 0.58 / Double(count))
        }
        return .init(columns: columns, rows: count, strokes: strokes)
    }

    func geometry(in scroll: TerminalHistoryScrollView, columns: Int) -> TerminalMinimapGeometry? {
        guard let text = scroll.documentView as? NSTextView else { return nil }
        let height = text.layoutManager?.defaultLineHeight(for: text.font ?? .terminal) ?? 16
        return .init(
            rows: max(1, lines.count + Int(2 * text.textContainerInset.height / height)),
            visibleRows: max(1, Int(scroll.contentView.bounds.height / height)),
            topRow: max(0, Int(scroll.contentView.bounds.minY / height)), columns: columns,
            cellAspectRatio: height
                / max(1, ("M" as NSString).size(withAttributes: [.font: text.font ?? .terminal]).width))
    }
}
