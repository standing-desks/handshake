import Foundation
import OSLog
import SwiftTerm

/// Live output and input never await this task. Historical emulation and decoding stay on a
/// separate actor; the main actor only installs bounded pages of already interpreted rows.
@MainActor
enum TerminalRestoration {
    static func restore(
        history: [UInt64], current: UInt64?, client: CoreClient, view: MetalTerminalView
    ) async throws -> UInt64 {
        var currentOffset: UInt64 = 0
        var discardedEarlier = false
        let sources = history + (current.map { [$0] } ?? [])
        view.minimapState?.historyLoadStarted(sources)
        defer { for id in sources { view.minimapState?.historyLoadFinished(id) } }
        for id in sources.reversed() {
            try Task.checkCancellation()
            defer { view.minimapState?.historyLoadFinished(id) }
            if id != current && discardedEarlier { continue }
            do {
                let index = try await restoreSource(id, isCurrent: id == current, client: client, view: view)
                if id == current {
                    currentOffset = index.sourceOffset
                    discardedEarlier = index.clearsHistory
                    view.minimapState?.received(through: currentOffset)
                }
            } catch is CancellationError { throw CancellationError() } catch {
                if id == current { throw error }
                terminalLogger.error(
                    "Could not restore terminal \(id): \(error.localizedDescription, privacy: .public)")
            }
        }
        view.minimapState?.refresh()
        return currentOffset
    }

    private static func restoreSource(
        _ id: UInt64, isCurrent: Bool, client: CoreClient, view: MetalTerminalView
    ) async throws -> TerminalDisplayIndex {
        let terminal = view.getTerminal()
        var attachment = terminal.beginDisplayHistoryAttachment()
        retry: while true {
            try Task.checkCancellation()
            let columns = terminal.cols
            let screenRows = terminal.rows
            let worker = TerminalHistoryWorker()
            let index = try await worker.prepare(terminalID: id, columns: columns, rows: screenRows, client: client)
            for page in index.pages.indices.reversed() {
                let rows = try await worker.pageRows(index: index, page: page, terminalID: id, client: client)
                try Task.checkCancellation()
                guard view.getTerminal() === terminal, terminal.acceptsDisplayHistory(attachment) else {
                    throw CancellationError()
                }
                if terminal.cols != columns || terminal.rows != screenRows {
                    guard isCurrent || terminal.discardDisplayHistory(attachment) else { throw CancellationError() }
                    attachment = terminal.beginDisplayHistoryAttachment()
                    continue retry
                }
                let inserted: Int
                if isCurrent, page == index.pages.count - 1 {
                    terminal.replaceDisplayHistory(
                        rows, cursorColumn: index.cursorColumn, cursorRow: index.cursorRow, sourceRows: index.screenRows
                    )
                    view.minimapState?.currentHistoryDidReplace()
                    attachment = terminal.beginDisplayHistoryAttachment()
                    inserted = 0
                } else {
                    inserted = terminal.prependDisplayHistory(rows)
                }
                view.displayHistoryChanged()
                if isCurrent || inserted > 0 {
                    let sourceRow = index.pageCounts.prefix(page).reduce(0, +) + (isCurrent ? 0 : rows.count - inserted)
                    view.minimapState?.historyDidLoad(
                        terminalID: id, sourceOffset: index.sourceOffset, sourceRow: sourceRow, columns: columns,
                        inserted: isCurrent ? 0 : inserted)
                }
                await Task.yield()
            }
            return index
        }
    }
}
