import Foundation
import SwiftUI
import Testing

@testable import Handshake

/// Sessions hold their file and browser tabs; core holds which session a workflow belongs to.
@MainActor
struct WorkspaceTabsSessionTests {
    private func store() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "WorkspaceTabsSessionTests-\(UUID())"))
    }

    @Test func pagesBelongToTheSessionThatOpensThemAndPersist() throws {
        let defaults = try store()
        let model = WorkspaceTabsModel(folder: "/tmp/pages", defaults: defaults)
        model.adopt("file:/tmp/a.swift", session: 10)
        model.adopt("browser:\(UUID())", session: 20)
        model.adopt("workflow:1", session: 10)
        #expect(model.holds("file:/tmp/a.swift", session: 10))
        #expect(!model.holds("file:/tmp/a.swift", session: 20))
        #expect(!model.holds("workflow:1", session: 10), "Core holds which session a workflow belongs to")
        let restored = WorkspaceTabsModel(folder: "/tmp/pages", defaults: defaults)
        #expect(restored.arrangement(10).pages == ["file:/tmp/a.swift"])
        #expect(restored.arrangement(20).pages.count == 1)
    }

    @Test func arrangementsSavedBeforeSessionsHeldPagesStillDecode() throws {
        let defaults = try store()
        let arrangement = #"{"order":["workflow:2","workflow:1"],"pins":["workflow:2"],"selection":"workflow:1"}"#
        let json = #"{"arrangements":{"10":"# + arrangement + #"},"files":[],"closed":[]}"#
        defaults.set(Data(json.utf8), forKey: "tabManagement:" + FolderWindows.canonicalPath("/tmp/legacy"))
        let model = WorkspaceTabsModel(folder: "/tmp/legacy", defaults: defaults)
        #expect(model.arrangement(10).order == ["workflow:2", "workflow:1"])
        #expect(model.arrangement(10).pins == ["workflow:2"])
        #expect(model.arrangement(10).selection == "workflow:1")
        #expect(model.arrangement(10).pages.isEmpty)
    }

    @Test func pagesNoListedSessionHoldsJoinTheSelectedSession() throws {
        let model = WorkspaceTabsModel(folder: "/tmp/unheld", defaults: try store())
        model.adopt("file:/tmp/held.swift", session: 20)
        model.adopt("file:/tmp/orphan.swift", session: 30)
        let browser = "browser:\(UUID())"
        model.adoptUnheld(
            ["file:/tmp/new.swift", browser, "file:/tmp/held.swift", "file:/tmp/orphan.swift", "workflow:4"],
            session: 10, sessions: [10, 20])
        #expect(model.arrangement(10).pages == ["file:/tmp/new.swift", browser, "file:/tmp/orphan.swift"])
        #expect(model.arrangement(20).pages == ["file:/tmp/held.swift"])
    }

    @Test func movingAPageBetweenSessionsIsUndoableButReorderingIsNot() async throws {
        let files = FileTabsModel()
        let browsers = BrowserTabsModel(selection: files.contentSelection)
        defer { browsers.closeAll() }
        let model = WorkspaceTabsModel(folder: "/tmp/undo", defaults: try store())
        let (moved, other) = (
            WorkspaceTabsModel.browser(browsers.create().id), WorkspaceTabsModel.browser(browsers.create().id)
        )
        model.adoptUnheld([moved, other], session: 10, sessions: [10])
        files.showWorkflows()
        let navigator = WorkspaceTabNavigator(
            client: CoreClient(transport: DeferredBrowserTransport()), model: model, files: files, browsers: browsers,
            layouts: WorkflowLayouts(fileURL: FileManager.default.temporaryDirectory.appending(path: "\(UUID()).json")),
            folder: "/tmp/undo", selection: .constant(WorkflowTabSelection()), currentSession: 10)
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        try await navigator.move(other, from: 10, to: 10, at: .before(moved), undoManager: undo)
        undo.endUndoGrouping()
        #expect(undo.undoActionName.isEmpty, "Reordering within a session registers nothing")
        undo.beginUndoGrouping()
        try await navigator.move(moved, from: 10, to: 20, undoManager: undo)
        undo.endUndoGrouping()
        #expect(model.holds(moved, session: 20) && !model.holds(moved, session: 10))
        #expect(undo.undoActionName == "Move Tab")
        undo.undo()
        try await waitUntil { model.holds(moved, session: 10) && !model.holds(moved, session: 20) }
        #expect(undo.canRedo)
    }

    @Test func pagesAgentsOpenJoinTheAgentsSessionWhileItExists() throws {
        let model = WorkspaceTabsModel(folder: "/tmp/agents", defaults: try store())
        let (agent, orphan) = ("browser:\(UUID())", "browser:\(UUID())")
        model.adoptUnheld([agent, orphan], session: 10, sessions: [10, 20], owners: [agent: 20, orphan: 30])
        #expect(model.arrangement(20).pages == [agent])
        #expect(model.arrangement(10).pages == [orphan])
    }

    @Test func movingToAnotherSessionUnpinsAndKeepsPinnedTabsFirst() throws {
        let model = WorkspaceTabsModel(folder: "/tmp/transfer", defaults: try store())
        model.reconcile(["workflow:1", "workflow:2"], session: 10)
        model.togglePin("workflow:1", session: 10)
        let destination = ["workflow:5", "workflow:6"]
        model.reconcile(destination, session: 20)
        model.togglePin("workflow:5", session: 20)
        let kept = model.transfer(
            "workflow:1", from: 10, to: 20, at: .before("workflow:5"), references: destination + ["workflow:1"])
        #expect(kept)
        #expect(model.arrangement(20).order == ["workflow:5", "workflow:1", "workflow:6"])
        #expect(!model.arrangement(20).pins.contains("workflow:1"))
        #expect(!model.arrangement(10).order.contains("workflow:1"))
        #expect(model.arrangement(10).pins.isEmpty)
        model.transfer(
            "workflow:6", from: 20, to: 20, at: .before("workflow:1"), references: model.arrangement(20).order)
        #expect(model.arrangement(20).order == ["workflow:5", "workflow:6", "workflow:1"])
        model.transfer("workflow:6", from: 20, to: 20, at: .end, references: model.arrangement(20).order)
        #expect(model.arrangement(20).order == ["workflow:5", "workflow:1", "workflow:6"])
    }

    @Test func aFileMovedToASessionThatHoldsItMerges() throws {
        let model = WorkspaceTabsModel(folder: "/tmp/merge", defaults: try store())
        let file = "file:/tmp/shared.swift"
        model.adopt(file, session: 10)
        model.adopt(file, session: 20)
        #expect(model.otherHolders(of: file, besides: 10) == [20])
        let kept = model.transfer(file, from: 10, to: 20, at: .end, references: [file])
        #expect(!kept)
        #expect(!model.holds(file, session: 10))
        #expect(model.arrangement(20).pages == [file])
    }

    @Test func releasingReportsWhetherAnotherSessionStillHoldsTheTab() throws {
        let model = WorkspaceTabsModel(folder: "/tmp/release", defaults: try store())
        let file = "file:/tmp/shared.swift"
        model.adopt(file, session: 10)
        model.adopt(file, session: 20)
        model.select(file, session: 10)
        #expect(model.release(file, session: 10))
        #expect(model.arrangement(10).selection == nil)
        #expect(!model.release(file, session: 20))
        model.adopt(file, session: 10)
        model.adopt(file, session: 30)
        model.releaseEverywhere(file)
        #expect(!model.holds(file, session: 10) && !model.holds(file, session: 30))
    }

    @Test func deletedSessionsForgetTheirArrangementsAndClosedTabs() throws {
        let model = WorkspaceTabsModel(folder: "/tmp/retain", defaults: try store())
        model.adopt("file:/tmp/a.swift", session: 10)
        model.adopt("file:/tmp/b.swift", session: 20)
        model.rememberClosed(.init(title: "b", sessionID: 20, reference: "file:/tmp/c.swift", index: 0, pinned: false))
        model.retainSessions([10])
        #expect(model.holds("file:/tmp/a.swift", session: 10))
        #expect(model.arrangement(20).pages.isEmpty)
        #expect(model.recentlyClosed(session: 20).isEmpty)
    }

    @Test func closedFilesAndPagesReopenInTheSessionTheyClosedFrom() throws {
        let model = WorkspaceTabsModel(folder: "/tmp/closed", defaults: try store())
        model.rememberClosed(
            .init(
                title: "notes", sessionID: 10, file: .init(path: "/tmp/notes.md", folder: "/tmp"),
                reference: "file:/tmp/notes.md", index: 0, pinned: false))
        #expect(model.recentlyClosed(session: 20).isEmpty)
        let closed = try #require(model.recentlyClosed(session: 10).first)
        model.didReopen(closed, session: 10)
        #expect(model.holds("file:/tmp/notes.md", session: 10))
    }

    @Test func eachSessionListsItsWorkflowsAndOnlyThePagesItHolds() throws {
        let model = WorkspaceTabsModel(folder: "/tmp/items", defaults: try store())
        let files = FileTabsModel()
        let browsers = BrowserTabsModel(selection: files.contentSelection, defaults: try store())
        let shared = files.open(path: "/tmp/shared.swift", folder: "/tmp")
        let mine = files.open(path: "/tmp/mine.swift", folder: "/tmp")
        model.adopt(WorkspaceTabsModel.file(shared.path), session: 10)
        model.adopt(WorkspaceTabsModel.file(mine.path), session: 10)
        model.adopt(WorkspaceTabsModel.file(shared.path), session: 20)
        let workflow = makeWorkflow(id: 7, session: 20)
        let first = WorkspaceTabItem.items(session: 10, workflows: [], files: files, browsers: browsers, model: model)
        let second = WorkspaceTabItem.items(
            session: 20, workflows: [workflow], files: files, browsers: browsers, model: model)
        #expect(first.map(\.id) == ["file:/tmp/shared.swift", "file:/tmp/mine.swift"])
        #expect(second.map(\.id) == ["workflow:7", "file:/tmp/shared.swift"])
    }

    @Test func switcherEntriesStayUniqueWhenAFileIsOpenInTwoSessions() {
        let first = WorkspaceTabItem(
            id: "file:/tmp/a.swift", title: "a.swift", detail: "", symbol: "doc.text", scope: 10)
        let second = WorkspaceTabItem(
            id: "file:/tmp/a.swift", title: "a.swift", detail: "", symbol: "doc.text", scope: 20)
        #expect(first.switcherKey == "10|file:/tmp/a.swift")
        #expect(first.switcherKey != second.switcherKey)
        #expect(WorkspaceTabItem(id: "workflow:1", title: "", detail: "", symbol: "").switcherKey == "workflow:1")
    }

    @Test func sidebarActivityShowsTheMostUrgentWorkflowState() {
        func activity(_ kind: CoreWorkflow.Kind, _ status: CoreWorkflow.Status) -> WorkspaceTabItem.Activity? {
            WorkspaceTabItem(
                id: "workflow:1", title: "Workflow", detail: "", symbol: "person",
                workflow: makeWorkflow(id: 1, session: 10, kind: kind, status: status)
            ).activity
        }
        #expect(activity(.singleAgent, .running) == .running)
        #expect(activity(.terminal, .running) == nil, "A shell isn't agent work")
        #expect(activity(.singleAgent, .completed) == .done)
        #expect(activity(.singleAgent, .failed) == .needsAttention)
        #expect(activity(.terminal, .interrupted) == .needsAttention)
        #expect([WorkspaceTabItem.Activity.done, .needsAttention, .running].max() == .needsAttention)
    }

    private func makeWorkflow(
        id: UInt64, session: UInt64, kind: CoreWorkflow.Kind = .terminal, status: CoreWorkflow.Status = .running
    ) -> CoreWorkflow {
        CoreWorkflow(
            workflowID: id, sessionID: session, name: "Terminal", kind: kind, terminalID: id, status: status,
            startedAt: 0, endedAt: nil)
    }
}
