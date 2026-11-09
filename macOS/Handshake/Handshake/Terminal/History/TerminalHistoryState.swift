import Foundation
import Observation

@MainActor
@Observable
final class TerminalHistoryState {
    enum Status {
        case loading
        case ready(TerminalHistorySnapshot)
        case expired
        case failed(String)
    }

    private(set) var status: Status = .loading
    private(set) var minimapRows: [UInt64: Int] = [:]
    @ObservationIgnored private let worker = TerminalTraceHistoryWorker()
    @ObservationIgnored private let indexWorker = TerminalIndexWorker()

    func load(_ target: TraceTerminalTarget, client: CoreClient) async {
        status = .loading
        minimapRows = [:]
        do {
            let snapshot = try await worker.load(target, client: client)
            try Task.checkCancellation()
            status = .ready(snapshot)
        } catch TerminalTraceHistoryWorker.HistoryFailure.expired { status = .expired } catch is CancellationError {
            return
        } catch { if !Task.isCancelled { status = .failed(error.localizedDescription) } }
    }

    func updateMinimap(_ markers: [TraceMinimapMarker], target: TraceTerminalTarget, client: CoreClient) async {
        guard case .ready(let frozen) = status else { return }
        do {
            let index = try await indexWorker.index(
                terminalID: target.anchor.terminalID, end: frozen.offset,
                points: markers.compactMap { marker in
                    marker.anchor.map {
                        .init(id: marker.id, anchor: $0, inputText: marker.inputText)
                    }
                }, columns: frozen.terminal.cols, rows: frozen.terminal.rows, client: client)
            try Task.checkCancellation()
            guard case .ready(let current) = status, current.id == frozen.id else { return }
            minimapRows = index.rows.compactMapValues { row in
                frozen.lines.indices.contains(row.row) && frozen.lines[row.row] == row.text ? row.row : nil
            }
        } catch is CancellationError { return } catch {
            if !Task.isCancelled { minimapRows = [:] }
        }
    }
}
