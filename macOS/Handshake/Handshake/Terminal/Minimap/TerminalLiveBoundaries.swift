import SwiftTerm

/// Retain recent exact byte boundaries so a hook arriving after its PTY chunk can reuse parsed
/// state. The cap bounds memory; older or overwritten boundaries use the background index.
struct TerminalLiveBoundaries {
    private struct Entry {
        var anchor: TerminalMinimapAnchor
        let prepended: Int
        let epoch: UInt64
    }
    private var entries: [UInt64: Entry] = [:]
    private var offsets: [UInt64] = []
    private var head = 0

    mutating func capture(offset: UInt64, terminal: Terminal, prepended: Int) {
        guard !terminal.isCurrentBufferAlternate,
            let anchor = TerminalMinimapAnchor(terminal: terminal, row: terminal.liveCursorRow)
        else { return }
        if entries[offset] == nil { offsets.append(offset) }
        entries[offset] = .init(anchor: anchor, prepended: prepended, epoch: terminal.displayHistoryEpoch)
        while offsets.count - head > 8192 {
            entries[offsets[head]] = nil
            head += 1
        }
        if head > 8192 {
            offsets.removeFirst(head)
            head = 0
        }
    }

    func row(for marker: TraceMinimapMarker, terminal: Terminal, prepended: Int) -> Int? {
        guard let point = marker.anchor, point.boundarySizes != nil,
            var saved = entries[point.byteOffset], saved.epoch == terminal.displayHistoryEpoch
        else { return nil }
        saved.anchor.historyWasPrepended(prepended - saved.prepended)
        guard let row = saved.anchor.resolve(terminal: terminal) else { return nil }
        guard let prompt = marker.inputText else { return row }
        let minimum = max(0, row - terminal.rows)
        return TerminalMinimapGeometry.inputRow(before: row, matching: prompt, in: terminal, minimumRow: minimum)
            ?? TerminalMinimapGeometry.inputRow(
                before: max(0, row - 1), matching: prompt, in: terminal, minimumRow: minimum)
    }
}
