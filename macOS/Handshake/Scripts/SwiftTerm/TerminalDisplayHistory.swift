// Handshake's focused SwiftTerm integration. These values contain no emulator or UI references.
import Foundation

public struct TerminalDisplayCell: Codable, Sendable {
    public let text: String
    public let width: Int8
    public let attribute: Attribute
    public let link: String?
}

public struct TerminalDisplayRow: Codable, Sendable {
    public let cells: [TerminalDisplayCell]
    public let wrapped: Bool
    public let mode: BufferLine.RenderLineMode
    public let bidi: BidiPresentationState
}

/// Main-actor attachment token used to reject resets and roll back only imported history on reflow.
public final class TerminalHistoryAttachment {
    fileprivate let buffer: Buffer
    fileprivate let following: BufferLine
    fileprivate let recycled: UInt64
    fileprivate let epoch: UInt64
    fileprivate init(buffer: Buffer, following: BufferLine, epoch: UInt64) {
        self.buffer = buffer
        self.following = following
        self.recycled = following.recycleGeneration
        self.epoch = epoch
    }
}

extension Terminal {
    public var displayHistoryBuffer: Buffer { normalBuffer }
    public var liveCursorRow: Int { buffer.yBase + buffer.y }
    public var normalHistoryCount: Int { normalBuffer.lines.count }
    public var displayHistoryCount: Int {
        normalBuffer.lines.count + (isCurrentBufferAlternate ? altBuffer.lines.count : 0)
    }

    public func displayHistoryLine(at row: Int) -> BufferLine? {
        guard row >= 0 && row < displayHistoryCount else { return nil }
        return row < normalBuffer.lines.count
            ? normalBuffer.lines[row] : altBuffer.lines[row - normalBuffer.lines.count]
    }

    public func beginDisplayHistoryAttachment() -> TerminalHistoryAttachment {
        TerminalHistoryAttachment(buffer: normalBuffer, following: normalBuffer.lines[0], epoch: displayHistoryEpoch)
    }

    public func acceptsDisplayHistory(_ attachment: TerminalHistoryAttachment) -> Bool {
        normalBuffer === attachment.buffer && displayHistoryEpoch == attachment.epoch
            && attachment.following.recycleGeneration == attachment.recycled
    }

    /// Undo only rows older than the original attachment boundary. The live screen is untouched.
    @discardableResult
    public func discardDisplayHistory(_ attachment: TerminalHistoryAttachment) -> Bool {
        guard acceptsDisplayHistory(attachment) else { return false }
        guard
            let amount = (0..<normalBuffer.lines.count).first(where: { normalBuffer.lines[$0] === attachment.following }
            )
        else { return false }
        normalBuffer.lines.trimStart(count: amount)
        normalBuffer.linesTop += amount
        normalBuffer.yBase = max(0, normalBuffer.yBase - amount)
        normalBuffer.yDisp = max(0, normalBuffer.yDisp - amount)
        for selection in selections { selection.value?.shiftForHistoryPrepend(-amount) }
        refresh(startRow: 0, endRow: rows - 1)
        return true
    }

    /// Install a read-only invocation's parsed screen. Never use this on a live process.
    public func replaceDisplayHistory(
        _ rows: [TerminalDisplayRow], cursorColumn: Int = 0, cursorRow: Int? = nil, sourceRows: Int? = nil
    ) {
        displayHistoryEpoch &+= 1
        for selection in selections { selection.value?.active = false }
        normalBuffer.linesTop = 0
        normalBuffer.lines.count = 0
        normalBuffer.yBase = 0
        normalBuffer.yDisp = 0
        normalBuffer.x = 0
        normalBuffer.y = 0
        _ = prependDisplayHistory(rows)
        normalBuffer.fillViewportRows()
        normalBuffer.yBase = max(0, normalBuffer.lines.count - self.rows)
        normalBuffer.yDisp = normalBuffer.yBase
        normalBuffer.x = max(0, min(cols, cursorColumn))
        let absoluteCursor = max(0, rows.count - (sourceRows ?? self.rows)) + (cursorRow ?? (self.rows - 1))
        normalBuffer.y = max(0, min(self.rows - 1, absoluteCursor - normalBuffer.yBase))
    }

    /// Copy only the requested page. Grapheme and hyperlink identifiers are local to an emulator,
    /// so resolve them before crossing an isolation boundary or persisting a row.
    public func displayHistoryRows(in range: Range<Int>) -> [TerminalDisplayRow] {
        range.clamped(to: 0..<displayHistoryCount).compactMap { row in
            guard let line = displayHistoryLine(at: row) else { return nil }
            return TerminalDisplayRow(
                cells: line.getData().map { cell in
                    TerminalDisplayCell(
                        text: String(getCharacter(for: cell)), width: cell.width,
                        attribute: cell.attribute, link: cell.getPayload() as? String)
                }, wrapped: line.isWrapped, mode: line.renderMode, bidi: line.bidiState)
        }
    }

    /// Prepend parsed historical rows to the normal buffer, preserving the live screen, cursor,
    /// modes, parser, alternate buffer, selection, and the content under a scrolled viewport.
    /// A full buffer retains its newer content and accepts only the nearest older rows.
    @discardableResult
    public func prependDisplayHistory(_ rows: [TerminalDisplayRow]) -> Int {
        let target = normalBuffer
        let available = target.lines.maxLength - target.lines.count
        let lines = rows.suffix(max(0, available)).map { row -> BufferLine in
            let line = BufferLine(cols: max(cols, row.cells.count), isWrapped: row.wrapped, bidiState: row.bidi)
            line.renderMode = row.mode
            for (column, cell) in row.cells.enumerated() {
                var value = makeCharData(attribute: cell.attribute, char: cell.text.first ?? "\0", size: cell.width)
                if let link = cell.link, let atom = makePayload(value: link) { value.setPayload(atom: atom) }
                line[column] = value
            }
            return line
        }
        let amount = target.lines.prependHistory(lines)
        guard amount > 0 else { return 0 }
        target.yBase += amount
        target.yDisp += amount
        if buffer === target {
            for weakSelection in selections {
                weakSelection.value?.shiftForHistoryPrepend(amount)
            }
            refresh(startRow: 0, endRow: self.rows - 1)
        }
        return amount
    }
}

extension SelectionService {
    fileprivate func shiftForHistoryPrepend(_ amount: Int) {
        guard active else { return }
        setSelection(
            start: Position(col: start.col, row: start.row + amount),
            end: Position(col: end.col, row: end.row + amount))
    }
}

#if os(macOS)
    extension TerminalView {
        /// Publish a parsed-row update without feeding historical protocol bytes or following output.
        public func displayHistoryChanged() {
            updateScroller()
            updateDisplay()
        }
    }
#endif
