import AppKit
import SwiftUI

/// A folder window owns terminal presentations for the lifetime of their core terminal IDs.
/// Attaching a SwiftUI surface neither recreates an emulator nor restarts its output consumer.
@MainActor
final class TerminalPresentationStore {
    struct Presentation {
        let view: MetalTerminalView
        let controller: TerminalController
        let minimap: TerminalMinimapState
    }

    private var presentations: [UInt64: Presentation] = [:]

    func presentation(
        terminalID: UInt64, client: CoreClient, minimap: TerminalMinimapState, failureMessage: Binding<String?>
    ) -> Presentation {
        if let existing = presentations[terminalID] {
            existing.controller.failureMessage = failureMessage
            return existing
        }
        let view = MetalTerminalView(frame: .zero)
        let controller = TerminalController(coreClient: client, terminalID: terminalID, failureMessage: failureMessage)
        let presentation = Presentation(view: view, controller: controller, minimap: minimap)
        presentations[terminalID] = presentation
        return presentation
    }

    func minimap(terminalID: UInt64, fallback: TerminalMinimapState) -> TerminalMinimapState {
        presentations[terminalID]?.minimap ?? fallback
    }

    func remove(terminalID: UInt64) {
        presentations.removeValue(forKey: terminalID)?.controller.stop()
    }

    func removeAll() {
        for presentation in presentations.values { presentation.controller.stop() }
        presentations.removeAll()
    }
}

/// SwiftUI owns this attachment, while the window retains its native terminal. A late dismantle
/// from an older attachment cannot hide a terminal that has already moved to a new surface.
final class TerminalHostingView: NSView {
    let terminal: MetalTerminalView

    init(terminal: MetalTerminalView) {
        self.terminal = terminal
        super.init(frame: terminal.frame)
        terminal.removeFromSuperview()
        addSubview(terminal)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        guard terminal.superview === self, bounds.width > 0, bounds.height > 0, terminal.frame != bounds else { return }
        terminal.frame = bounds
    }
}
