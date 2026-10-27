import Foundation
import Testing

@testable import Handshake

@MainActor
struct WorkspaceTabsTests {
    private func store() throws -> UserDefaults {
        let suite = "WorkspaceTabsTests-\(UUID())"
        return try #require(UserDefaults(suiteName: suite))
    }

    @Test func orderPinsAndSelectionPersistPerSessionAndFolder() throws {
        let defaults = try store()
        let model = WorkspaceTabsModel(folder: "/tmp/first", defaults: defaults)
        let ids = ["workflow:1", "workflow:2", "file:/tmp/server"]
        model.reconcile(ids, session: 10)
        model.move(ids[2], before: ids[0], references: ids, session: 10)
        model.togglePin(ids[1], session: 10)
        #expect(model.ordered(ids, session: 10) == [ids[1], ids[2], ids[0]])
        model.move(ids[1], by: 1, references: ids, session: 10)
        #expect(model.ordered(ids, session: 10).first == ids[1])
        model.select(ids[2], session: 10)
        let restored = WorkspaceTabsModel(folder: "/tmp/first", defaults: defaults)
        #expect(restored.ordered(ids, session: 10) == [ids[1], ids[2], ids[0]])
        #expect(restored.arrangement(10).selection == ids[2])
        #expect(restored.ordered(ids, session: 20) == ids)
        #expect(WorkspaceTabsModel(folder: "/tmp/other", defaults: defaults).ordered(ids, session: 10) == ids)
        restored.reconcile([ids[0], ids[2], "workflow:3"], session: 10)
        #expect(restored.ordered([ids[0], ids[2], "workflow:3"], session: 10) == [ids[2], ids[0], "workflow:3"])
    }

    @Test func onlyCompletionHasATopLevelTabIndicator() {
        for status in [CoreWorkflow.Status.running, .completed, .failed, .interrupted, .cancelled, .exited, .closed] {
            let item = WorkspaceTabItem(
                id: "workflow:1", title: "Terminal", detail: "", symbol: "terminal",
                workflow: makeWorkflow(id: 1, status: status))
            #expect(item.status == (status == .completed ? "Done" : nil))
            #expect(item.statusSymbol == (status == .completed ? "checkmark.circle" : nil))
        }
    }

    @Test func duplicateTitlesUseStableIDsAndShortestDistinctPaths() {
        let first = makeWorkflow(id: 1)
        let second = makeWorkflow(id: 2)
        #expect(WorkspaceTabItem.workflowTitles([first, second]) == [1: "Terminal · 1", 2: "Terminal · 2"])
        let server = FileEditorModel(path: "/repo/server/src/main.swift", folder: "/repo")
        let client = FileEditorModel(path: "/repo/client/src/main.swift", folder: "/repo")
        let readme = FileEditorModel(path: "/repo/README.md", folder: "/repo")
        let titles = WorkspaceTabItem.fileTitles([server, client, readme])
        #expect(titles[server.id] == "server/src/main.swift")
        #expect(titles[client.id] == "client/src/main.swift")
        #expect(titles[readme.id] == "README.md")
    }

    @Test func closedHistoryIsBoundedScopedAndRestoresPinAndPosition() throws {
        let defaults = try store()
        let model = WorkspaceTabsModel(folder: "/tmp/first", defaults: defaults)
        model.reconcile(["workflow:1", "workflow:2"], session: 10)
        for id in 1...25 {
            model.rememberClosed(
                .init(
                    title: "Terminal", sessionID: 10, workflowIDs: [UInt64(id)],
                    reference: "workflow:\(id)", index: 0, pinned: true))
        }
        let restored = WorkspaceTabsModel(folder: "/tmp/first", defaults: defaults)
        #expect(restored.recentlyClosed(session: 10).count == 20)
        #expect(restored.recentlyClosed(session: 20).isEmpty)
        let closed = try #require(restored.recentlyClosed(session: 10).first)
        restored.didReopen(closed, session: 10)
        #expect(restored.recentlyClosed(session: 10).count == 19)
        #expect(restored.arrangement(10).pins.contains(closed.reference))
        #expect(restored.ordered(["workflow:1", closed.reference], session: 10).first == closed.reference)
    }

    @Test func fileRestoreUsesPathsAndPreservesEditorsWithoutReplacingTheirBuffers() throws {
        let defaults = try store()
        let model = WorkspaceTabsModel(folder: "/tmp/first", defaults: defaults)
        let tabs = FileTabsModel()
        model.restoreFiles(into: tabs)
        let editor = tabs.open(path: "/tmp/server.swift", folder: "/tmp")
        editor.text = "buffer"
        model.rememberFiles(tabs.editors)
        model.restoreFiles(into: tabs)
        #expect(tabs.editors.count == 1)
        #expect(tabs.editors[0] === editor)
        #expect(tabs.editors[0].text == "buffer")
        let fresh = FileTabsModel()
        WorkspaceTabsModel(folder: "/tmp/first", defaults: defaults).restoreFiles(into: fresh)
        #expect(fresh.editors.map(\.path) == ["/tmp/server.swift"])
    }

    @Test func closeSelectionFollowsDisplayedNeighborsAcrossTabKinds() {
        let order = ["workflow:3", "file:/tmp/notes", "workflow:1", "workflow:2"]
        #expect(WorkspaceTabsModel.neighbor(in: order, closing: ["workflow:1"], selected: "workflow:1") == "workflow:2")
        #expect(WorkspaceTabsModel.neighbor(in: order, closing: ["workflow:2"], selected: "workflow:2") == "workflow:1")
        #expect(WorkspaceTabsModel.neighbor(in: order, closing: Set(order), selected: "workflow:1") == nil)
    }

    @Test func promotedSplitRootsKeepTheirTabPositionAndPinAfterReconciliation() throws {
        let model = WorkspaceTabsModel(folder: "/tmp/split", defaults: try store())
        model.reconcile(["workflow:2", "workflow:1"], session: 10)
        model.togglePin("workflow:1", session: 10)
        let previous = model.arrangement(10)
        model.reconcile(["workflow:2", "workflow:3"], session: 10)
        model.promote("workflow:1", to: "workflow:3", previous: previous, session: 10)
        #expect(model.ordered(["workflow:2", "workflow:3"], session: 10) == ["workflow:3", "workflow:2"])
        #expect(model.arrangement(10).pins == ["workflow:3"])
    }

    @Test func memoryRestorePreservesTheReadRouteAndReadOnlyMetadata() throws {
        let defaults = try store()
        let model = WorkspaceTabsModel(folder: "/tmp/memory", defaults: defaults)
        let tabs = FileTabsModel()
        model.restoreFiles(into: tabs)
        let request = CoreMemoryRequest(folder: "/tmp/memory", sourceID: "sqlite-source")
        let source = CoreMemorySource(
            id: "sqlite-source", title: "Agent memory", harness: .codex, scope: .folder,
            kind: .rawMemory, location: "/tmp/memory.sqlite", group: "Memory", format: "sqlite",
            modifiedAt: nil, example: false, association: nil)
        let editor = tabs.restore(path: source.location, folder: "/tmp", memoryRequest: request, source: source)
        model.rememberFiles(tabs.editors)
        let restored = FileTabsModel()
        WorkspaceTabsModel(folder: "/tmp/memory", defaults: defaults).restoreFiles(into: restored)
        let memory = try #require(restored.editors.first)
        #expect(memory.memoryRequest == editor.memoryRequest)
        #expect(memory.memorySource == source)
        #expect(!memory.isEditable)
        #expect(memory.previewFormat == nil)
    }

    private func makeWorkflow(id: UInt64, status: CoreWorkflow.Status = .running) -> CoreWorkflow {
        CoreWorkflow(
            workflowID: id, sessionID: 10, name: "Terminal", kind: .terminal,
            terminalID: id, status: status, startedAt: 0, endedAt: nil)
    }
}
