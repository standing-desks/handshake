import SwiftUI

/// The sidebar's sheets and alerts. The window presents them, so they stay open when the peek closes.
struct SidebarDialogs: ViewModifier {
    @Environment(CoreClient.self) private var coreClient
    @Environment(FileTabsModel.self) private var fileTabs
    @Environment(BrowserTabsModel.self) private var browsers
    @Bindable var presentation: SidebarPresentation
    let tabManagement: WorkspaceTabsModel

    func body(content: Content) -> some View {
        content
            .sheet(item: $presentation.sessionToRename) { session in
                SessionNameForm(name: session.name) { name in
                    presentation.run { try await coreClient.renameSession(sessionID: session.id, name: name) }
                }
                .appZoom()
            }
            .background {
                Color.clear.sheet(item: $presentation.tabToRename) { item in
                    TabRenameSheet(name: item.renameValue) { name in
                        if let workflow = item.workflow {
                            try await coreClient.renameWorkflow(workflowID: workflow.id, name: name)
                        } else if let browser = item.browser {
                            browser.customName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                    .appZoom()
                }
            }
            .alert(
                "Delete Session?",
                isPresented: Binding(
                    get: { presentation.sessionToDelete != nil },
                    set: { if !$0 { presentation.sessionToDelete = nil } })
            ) {
                Button("Cancel", role: .cancel) { presentation.sessionToDelete = nil }
                Button("Delete", role: .destructive) {
                    guard let session = presentation.sessionToDelete else { return }
                    presentation.sessionToDelete = nil
                    guard closePages(of: session.id) else { return }
                    presentation.run { try await coreClient.deleteSession(sessionID: session.id) }
                }
            } message: {
                let name = presentation.sessionToDelete?.name ?? ""
                Text("Deleting “\(name)” stops its shells and removes its workflows, files, and browser tabs.")
            }
            .alert(
                "Session Couldn't Be Updated",
                isPresented: Binding(
                    get: { presentation.failure != nil }, set: { if !$0 { presentation.failure = nil } })
            ) {
                Button("OK") { presentation.failure = nil }
            } message: {
                Text(presentation.failure ?? "")
            }
    }

    /// Closes the files and browser tabs that only this session holds. Unsaved files are confirmed first, so
    /// a cancel leaves the session and all of its tabs as they were.
    private func closePages(of session: UInt64) -> Bool {
        let owned = tabManagement.arrangement(session).pages.filter {
            tabManagement.otherHolders(of: $0, besides: session).isEmpty
        }
        let editors = fileTabs.editors.filter { owned.contains(WorkspaceTabsModel.file($0.path)) }
        guard fileTabs.close(Set(editors.map(\.id))) else { return false }
        for page in browsers.tabs where owned.contains(WorkspaceTabsModel.browser(page.id)) {
            browsers.close(page.id)
        }
        return true
    }
}
