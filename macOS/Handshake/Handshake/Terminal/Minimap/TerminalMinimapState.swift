import AppKit
import OSLog
import Observation
import SwiftTerm
import SwiftUI

@MainActor
@Observable
final class TerminalMinimapState {
    private(set) var geometry = TerminalMinimapGeometry()
    private(set) var strokes: [CGRect] = []
    private(set) var strokeColors: [SwiftUI.Color] = []
    private(set) var markerRows: [UInt64: Int] = [:]
    private(set) var geometryRevision = 0
    private(set) var indexRevision = 0
    private(set) var historyRevision = 0
    private(set) var loadingHistorySources: Set<UInt64> = []

    func historyLoadStarted(_ ids: [UInt64]) {
        loadingHistorySources.formUnion(ids)
        historyRevision += 1
    }
    func historyLoadFinished(_ id: UInt64) {
        loadingHistorySources.remove(id)
        historyRevision += 1
    }
    @ObservationIgnored private let indexWorker = TerminalIndexWorker()
    @ObservationIgnored private var historicalRowCount = 0
    @ObservationIgnored private var usesRecordedGeometry = false
    @ObservationIgnored private var historyEpoch: UInt64 = 0
    @ObservationIgnored private var normalBuffer: Buffer?
    @ObservationIgnored private var historySources: [UInt64: HistorySource] = [:]
    private struct HistorySource {
        var base: TerminalMinimapAnchor
        let sourceRow: Int
        let sourceOffset: UInt64
    }
    private(set) var receivedOffset: UInt64 = 0
    private(set) var failureMessage: String?
    @ObservationIgnored weak var view: MetalTerminalView?
    @ObservationIgnored weak var historyView: TerminalHistoryScrollView?
    @ObservationIgnored private var historyDrawing = TerminalHistoryMinimap()
    @ObservationIgnored private var anchors: [UInt64: TerminalMinimapAnchor] = [:]
    @ObservationIgnored private var boundaries = TerminalLiveBoundaries()
    @ObservationIgnored private var markerPrompts: [UInt64: String] = [:]
    @ObservationIgnored private var markerEvents: [UInt64: CoreTraceEvent] = [:]
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var dimensions: CGSize = .zero
    @ObservationIgnored private var unresolved: Set<UInt64> = []
    @ObservationIgnored private var indexing = false
    @ObservationIgnored private var attemptedOffset: UInt64 = 0
    @ObservationIgnored private var liveSizes: [CoreTranscriptSize] = []
    @ObservationIgnored private var isFeeding = false
    @ObservationIgnored private var replayPrefix: [TerminalReplayPrefix] = []

    func recordHistory(_ text: String, terminal: Terminal, source: CoreTraceAnchor? = nil) {
        replayPrefix.append(.init(text: text, columns: terminal.cols, rows: terminal.rows, source: source))
    }

    func recordSize(columns: Int, rows: Int) {
        guard !isFeeding, liveSizes.last?.columns != columns || liveSizes.last?.rows != rows else { return }
        // Replay starts at byte zero, so retain its resize prefix for this view's lifetime.
        liveSizes.append(.init(offset: receivedOffset, rows: rows, columns: columns))
        scheduleRefresh()
    }

    func beginFeed() {
        if let terminal = view?.getTerminal() {
            if normalBuffer == nil {
                normalBuffer = terminal.buffer
                historyEpoch = terminal.displayHistoryEpoch
            }
            recordSize(columns: terminal.cols, rows: terminal.rows)
        }
        captureBoundary(at: receivedOffset)
        isFeeding = true
    }

    func received(through offset: UInt64) {
        isFeeding = false
        receivedOffset = offset
        captureBoundary(at: offset)
        scheduleRefresh()
    }

    func scheduleRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            guard let self else { return }
            refreshTask = nil
            refresh()
        }
    }

    func refresh() {
        if let historyView {
            refreshHistory(historyView)
            return
        }
        guard let terminal = view?.getTerminal() else { return }
        if normalBuffer !== terminal.buffer || historyEpoch != terminal.displayHistoryEpoch {
            if !terminal.isCurrentBufferAlternate {
                normalBuffer = terminal.buffer
                historyEpoch = terminal.displayHistoryEpoch
                anchors = [:]
                boundaries = .init()
                markerRows = [:]
                historySources = [:]
                historicalRowCount = 0
            }
        }
        recordSize(columns: terminal.cols, rows: terminal.rows)
        let size = CGSize(width: terminal.cols, height: terminal.rows)
        if size != dimensions {
            dimensions = size
            geometryRevision += 1
        }
        let count = TerminalMinimapGeometry.lineCount(in: terminal)
        let font = view?.font ?? .terminal
        let cellWidth = ("M" as NSString).size(withAttributes: [.font: font]).width
        geometry = .init(
            rows: count, visibleRows: terminal.rows, topRow: terminal.getTopVisibleRow(), columns: terminal.cols,
            cellAspectRatio: (font.ascender - font.descender + font.leading).rounded(.up) / max(1, cellWidth))
        (strokes, strokeColors) = Self.sample(terminal, count: count, palette: view?.handshakePalette)
        if terminal.isCurrentBufferAlternate {
            markerRows = [:]
            return
        }
        var resolved: [UInt64: Int] = [:]
        var retained: [UInt64: TerminalMinimapAnchor] = [:]
        for (id, saved) in anchors {
            var anchor = saved
            guard let row = anchor.resolve(terminal: terminal) else { continue }
            resolved[id] = row
            retained[id] = anchor
        }
        anchors = retained
        markerRows = terminal.isCurrentBufferAlternate ? [:] : resolved
        if !indexing, !unresolved.isEmpty, attemptedOffset != receivedOffset {
            attemptedOffset = receivedOffset
            indexRevision += 1
        }
    }

    private static func sample(_ terminal: Terminal, count: Int, palette: TerminalPalette?) -> (
        [CGRect], [SwiftUI.Color]
    ) {
        var result: [CGRect] = []
        var colors: [SwiftUI.Color] = []
        for row in stride(from: 0, to: count, by: max(1, count / 350)) {
            guard let line = terminal.bufferLine(atRow: row) else { continue }
            let columns = min(line.count, terminal.cols)
            var start: Int?
            for column in 0...columns {
                let character = column < columns ? line[column].getCharacter() : "\0"
                let filled = column < columns && !character.isWhitespace && character != "\0"
                if filled && start == nil { start = column }
                if !filled, let lower = start {
                    result.append(
                        CGRect(
                            x: Double(lower) / Double(max(1, terminal.cols)), y: Double(row) / Double(count),
                            width: Double(column - lower) / Double(max(1, terminal.cols)), height: 0.58 / Double(count))
                    )
                    colors.append(TerminalMinimapInk.color(line[lower].attribute.fg, palette: palette))
                    start = nil
                }
            }
        }
        return (result, colors)
    }

}

extension TerminalMinimapState {
    func scroll(to row: Int) {
        if let scroll = historyView, let text = scroll.documentView as? NSTextView {
            let height = text.layoutManager?.defaultLineHeight(for: text.font ?? .terminal) ?? 16
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, CGFloat(row) * height)))
            scroll.reflectScrolledClipView(scroll.contentView)
            refreshHistory(scroll)
            return
        }
        view?.scrollTo(row: row)
        refresh()
    }

    private func captureBoundary(at offset: UInt64) {
        if let terminal = view?.getTerminal() {
            boundaries.capture(offset: offset, terminal: terminal, prepended: historicalRowCount)
        }
    }

    private func resolveLiveBoundaries(_ markers: [TraceMinimapMarker], terminal: Terminal) {
        for marker in markers where anchors[marker.id] == nil {
            guard let row = boundaries.row(for: marker, terminal: terminal, prepended: historicalRowCount) else {
                continue
            }
            anchors[marker.id] = TerminalMinimapAnchor(terminal: terminal, row: row)
        }
    }

    private func cachedMarkerRow(_ anchor: CoreTraceAnchor, in terminal: Terminal) -> Int? {
        guard let id = markerEvents.first(where: { $0.value.anchor == anchor })?.key,
            var saved = anchors[id]
        else { return nil }
        return saved.resolve(terminal: terminal)
    }

    /// Scroll using a retained marker, or resolve a late anchor on the background index actor.
    func scroll(
        to anchor: CoreTraceAnchor, in terminalID: UInt64? = nil,
        includingInput: Bool = false, inputText: String? = nil, client: CoreClient
    ) async throws -> Bool {
        guard let terminal = view?.getTerminal(), !terminal.isCurrentBufferAlternate else { return false }
        if !includingInput, inputText == nil, let row = cachedMarkerRow(anchor, in: terminal) {
            scroll(to: row)
            return true
        }
        let revision = geometryRevision
        let historical = anchor.terminalID != (terminalID ?? anchor.terminalID)
        let source = historySources[anchor.terminalID]
        let end = historical ? (source?.sourceOffset ?? 0) : receivedOffset
        guard anchor.byteOffset <= end else { return false }
        let result = try await indexWorker.index(
            terminalID: anchor.terminalID, end: end,
            points: [.init(id: 0, anchor: anchor, inputText: inputText, includesInput: includingInput)],
            sizes: historical || usesRecordedGeometry ? nil : liveSizes, prefix: historical ? [] : replayPrefix,
            columns: historical || usesRecordedGeometry ? terminal.cols : nil,
            rows: historical || usesRecordedGeometry ? terminal.rows : nil, client: client)
        try Task.checkCancellation()
        guard revision == geometryRevision else { throw CancellationError() }
        guard let saved = result.rows[0] else { return false }
        let candidate: Int
        if historical {
            guard var source = historySources[anchor.terminalID], let base = source.base.resolve(terminal: terminal)
            else { return false }
            historySources[anchor.terminalID] = source
            candidate = base + saved.row - source.sourceRow
        } else {
            candidate = saved.row + result.trimmed - terminal.buffer.totalLinesTrimmed + historicalRowCount
        }
        guard candidate >= 0, terminal.bufferLine(atRow: candidate)?.translateToString() == saved.text,
            saved.input.map({ $0 == TerminalMinimapGeometry.logicalLine(at: candidate, in: terminal) }) ?? true
        else { return false }
        scroll(to: candidate)
        if let view { view.window?.makeFirstResponder(view) }
        return true
    }

    func historyDidLoad(terminalID: UInt64, sourceOffset: UInt64, sourceRow: Int, columns: Int, inserted: Int = 0) {
        if normalBuffer == nil, let terminal = view?.getTerminal() {
            normalBuffer = terminal.buffer
            historyEpoch = terminal.displayHistoryEpoch
        }
        historicalRowCount += inserted
        if inserted > 0 {
            for id in anchors.keys { anchors[id]?.historyWasPrepended(inserted) }
            for id in historySources.keys { historySources[id]?.base.historyWasPrepended(inserted) }
        }
        if let terminal = view?.getTerminal() {
            if let base = TerminalMinimapAnchor(terminal: terminal, row: 0, normalHistory: true) {
                historySources[terminalID] = .init(base: base, sourceRow: sourceRow, sourceOffset: sourceOffset)
            }
        }
        historyRevision += 1
        scheduleRefresh()
    }

    func currentHistoryDidReplace() {
        boundaries = .init()
        usesRecordedGeometry = true
        anchors = [:]
        markerRows = [:]
        historySources = [:]
        historicalRowCount = 0
        if let terminal = view?.getTerminal() {
            normalBuffer = terminal.buffer
            historyEpoch = terminal.displayHistoryEpoch
        }
        geometryRevision += 1
    }

    /// Split only at trace boundaries already known to the presentation. Late hook events use
    /// the historical worker; normal live events never need to replay their prefix.
    func feed(_ bytes: ArraySlice<UInt8>, offset: UInt64, into view: MetalTerminalView) {
        beginFeed()
        let end = offset + UInt64(bytes.count)
        let points = markerEvents.compactMap { id, event -> (UInt64, CoreTraceAnchor)? in
            guard let anchor = event.anchor, anchor.byteOffset >= offset, anchor.byteOffset <= end,
                anchors[id] == nil
            else { return nil }
            return (id, anchor)
        }.sorted { $0.1.byteOffset < $1.1.byteOffset }
        var cursor = 0
        for (id, point) in points {
            let next = Int(point.byteOffset - offset)
            if next > cursor { view.feed(byteArray: bytes.dropFirst(cursor).prefix(next - cursor)) }
            cursor = next
            let terminal = view.getTerminal()
            guard !terminal.isCurrentBufferAlternate, point.boundarySizes != nil else { continue }
            let row = terminal.liveCursorRow
            let prompt = markerEvents[id].flatMap { _ in markerPrompts[id] }.flatMap {
                TerminalMinimapGeometry.inputRow(before: row, matching: $0, in: terminal)
            }
            anchors[id] = TerminalMinimapAnchor(terminal: terminal, row: prompt ?? row)
            unresolved.remove(id)
        }
        if cursor < bytes.count { view.feed(byteArray: bytes.dropFirst(cursor)) }
        received(through: end)
    }

    func returnToLive() {
        scroll(to: geometry.maximumTop)
        if let view { view.window?.makeFirstResponder(view) }
    }

}

extension TerminalMinimapState {
    func showHistory(text: String, rows: [UInt64: Int]) {
        if let drawing = historyDrawing.update(text) {
            strokeColors = []
            geometry.columns = drawing.columns
            geometry.rows = drawing.rows
            strokes = drawing.strokes
        }
        markerRows = rows
        if let historyView { refreshHistory(historyView) }
    }

    private func refreshHistory(_ scroll: TerminalHistoryScrollView) {
        if let updated = historyDrawing.geometry(in: scroll, columns: geometry.columns) { geometry = updated }
    }

    private func prepareMarkers(_ markers: [TraceMinimapMarker]) -> Set<UInt64> {
        let ids = Set(markers.map(\.id))
        let events = Dictionary(uniqueKeysWithValues: markers.map { ($0.id, $0.event) })
        anchors = anchors.filter { events[$0.key] == markerEvents[$0.key] && ids.contains($0.key) }
        markerEvents = events
        markerPrompts = Dictionary(
            uniqueKeysWithValues: markers.compactMap { marker in marker.inputText.map { (marker.id, $0) } })
        markerRows = markerRows.filter { anchors[$0.key] != nil }
        if let terminal = view?.getTerminal(), !terminal.isCurrentBufferAlternate {
            resolveLiveBoundaries(markers, terminal: terminal)
        }
        unresolved = ids.subtracting(anchors.keys)
        return ids
    }

    func loadMarkers(_ markers: [TraceMinimapMarker], terminalID: UInt64, client: CoreClient) async {
        let ids = prepareMarkers(markers)
        if unresolved.isEmpty {
            refresh()
            return
        }
        guard !unresolved.isEmpty, let terminal = view?.getTerminal(), !terminal.isCurrentBufferAlternate,
            usesRecordedGeometry || liveSizes.first?.offset == 0
        else { return }
        let ready = markers.filter { unresolved.contains($0.id) && ($0.anchor?.byteOffset ?? 0) <= receivedOffset }
        guard !ready.isEmpty else { return }
        let revision = geometryRevision
        let end = receivedOffset
        indexing = true
        attemptedOffset = end
        defer {
            indexing = false
            scheduleRefresh()
        }
        do {
            let result = try await indexWorker.index(
                terminalID: terminalID, end: end,
                points: ready.compactMap { marker in
                    marker.anchor.map { .init(id: marker.id, anchor: $0, inputText: marker.inputText) }
                },
                sizes: usesRecordedGeometry ? nil : liveSizes, prefix: replayPrefix,
                columns: usesRecordedGeometry ? terminal.cols : nil, rows: usesRecordedGeometry ? terminal.rows : nil,
                client: client)
            try Task.checkCancellation()
            guard revision == geometryRevision, terminal.cols == result.columns, terminal.rows == result.screenRows
            else { return }
            for (id, saved) in result.rows where ids.contains(id) {
                let row = saved.row + result.trimmed - terminal.buffer.totalLinesTrimmed + historicalRowCount
                guard row >= 0, terminal.bufferLine(atRow: row)?.translateToString() == saved.text else { continue }
                anchors[id] = TerminalMinimapAnchor(terminal: terminal, row: row)
            }
            unresolved = ids.subtracting(anchors.keys)
            failureMessage = nil
            refresh()
        } catch is CancellationError { return } catch {
            guard !Task.isCancelled, revision == geometryRevision else { return }
            failureMessage = "Trace positions couldn't load."
            terminalLogger.error("Minimap indexing failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
