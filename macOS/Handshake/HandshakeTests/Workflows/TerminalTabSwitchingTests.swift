import AppKit
import SwiftTerm
import SwiftUI
import Testing

@testable import Handshake

@MainActor
struct TerminalTabSwitchingTests {
    @Test(arguments: [CoreWorkflow.Kind.terminal, .singleAgent, .agents])
    func switchingTabsKeepsTheEmulatorLatestOutputAndScrollPosition(kind: CoreWorkflow.Kind) async throws {
        let workflows = (1...2).map { id in
            CoreWorkflow(
                workflowID: UInt64(id), sessionID: 1, name: "Agent \(id)", kind: kind,
                terminalID: UInt64(id),
                agents: kind == .agents ? [.init(agentID: UInt64(id), role: "Builder", terminalID: UInt64(id))] : [],
                status: .running, startedAt: 0, endedAt: nil, restored: false)
        }
        var snapshot = CoreSnapshot.testReady()
        snapshot.terminals = workflows.map { .init(terminalID: $0.terminalID, status: .running) }
        let transport = DelayedStartTransport(snapshot: snapshot)
        let client = CoreClient(transport: transport)
        client.start()
        try await client.waitUntilRunning()
        defer { Task { await client.stop() } }
        let path = TemporaryPath()
        let layouts = WorkflowLayouts(fileURL: path.url.appending(path: "layouts.json"))
        let tabs = FileTabsModel()
        let browsers = BrowserTabsModel(selection: tabs.contentSelection)
        let navigation = TraceTerminalNavigation()
        let catalog = HarnessModelCatalog()
        func content(selected: UInt64) -> some View {
            var selection = WorkflowTabSelection()
            selection.selectedID = selected
            return WorkspaceViewport(contentHeight: 480) {
                WorkflowPaneCanvas(
                    folder: "/", workflows: workflows, sessionID: 1,
                    selection: .constant(selection), isVisible: true,
                    reportFailure: { _ in }, closePane: { _ in })
            }
            .environment(client).environment(layouts).environment(tabs).environment(browsers)
            .environment(navigation).environment(catalog)
        }
        let hosting = NSHostingView(rootView: content(selected: 1))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 480), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.contentView = hosting
        defer { window.contentView = nil }
        try await waitUntil {
            hosting.layoutSubtreeIfNeeded()
            return Self.terminals(in: hosting).count == 2
        }
        let original = Self.terminals(in: hosting)
        for (index, view) in original.enumerated() {
            view.automaticallyFocuses = false
            view.feed(text: String(repeating: "history \(index)\r\n", count: 8_000) + "LATEST_\(index)")
        }
        try await Self.switchTabs(hosting, original: original) { content(selected: $0) }
    }

    @Test func retiredAttachmentCannotResizeANewerTerminalHost() {
        let terminal = MetalTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let retired = TerminalHostingView(terminal: terminal)
        retired.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        let current = TerminalHostingView(terminal: terminal)
        current.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        current.layout()
        retired.layout()
        #expect(terminal.superview === current)
        #expect(terminal.frame == current.bounds)
    }

    private static func switchTabs<Content: View>(
        _ hosting: NSHostingView<Content>, original: [MetalTerminalView], content: (UInt64) -> Content
    ) async throws {
        for selected: UInt64 in [2, 1, 2, 1] {
            let previous = Self.terminals(in: hosting).first { !$0.isHidden }
            for (index, view) in original.enumerated() { view.scrollTo(row: index == 0 ? 57 : Int.max) }
            hosting.rootView = content(selected)
            try await waitUntil {
                hosting.layoutSubtreeIfNeeded()
                let visible = Self.terminals(in: hosting).filter { !$0.isHidden }
                return visible.count == 1 && visible.first !== previous
            }
            let current = Self.terminals(in: hosting)
            #expect(Set(current.map(ObjectIdentifier.init)) == Set(original.map(ObjectIdentifier.init)))
            for (index, view) in original.enumerated() {
                #expect(
                    String(data: view.getTerminal().getBufferAsData(), encoding: .utf8)?.contains("LATEST_\(index)")
                        == true)
            }
            let visible = try #require(current.first { !$0.isHidden })
            let terminal = visible.getTerminal()
            if visible === original[0] {
                #expect(terminal.getTopVisibleRow() == 57)
            } else {
                #expect(terminal.getTopVisibleRow() >= TerminalMinimapGeometry.lineCount(in: terminal) - terminal.rows)
            }
        }
    }

    private static func terminals(in view: NSView) -> [MetalTerminalView] {
        if let terminal = view as? MetalTerminalView { return [terminal] }
        return view.subviews.flatMap { terminals(in: $0) }
    }
}
