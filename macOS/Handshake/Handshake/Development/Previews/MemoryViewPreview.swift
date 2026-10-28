import SwiftUI

struct MemoryViewPreview: View {
    @State private var model = MemoryModel()
    @State private var tabs: FileTabsModel
    @State private var browsers: BrowserTabsModel

    init() {
        let tabs = FileTabsModel()
        _tabs = State(initialValue: tabs)
        _browsers = State(initialValue: BrowserTabsModel(selection: tabs.contentSelection))
    }
    @State private var client = CoreClient(transport: CoreWorker(dataDirectory: AppPaths.previewDirectory))

    var body: some View {
        HStack(spacing: 0) {
            MemorySidebar(
                model: model, folder: NSHomeDirectory(), contentHeight: 650 - SidebarLayout.sectionHeaderHeight
            ) {
                guard let source = model.selected else { return }
                Task {
                    try? await tabs.openMemory(
                        request: model.request(folder: NSHomeDirectory(), sourceID: source.id), client: client)
                }
            }.frame(width: 285)
            VStack(spacing: 0) {
                ManagedWorkflowTabs(
                    items: tabs.editors.map {
                        WorkspaceTabItem(
                            id: WorkspaceTabsModel.file($0.path), title: $0.displayName,
                            detail: $0.path, symbol: "doc.text", fileID: $0.id)
                    },
                    selected: tabs.selected.map { WorkspaceTabsModel.file($0.path) },
                    dragScope: "memory-source-preview", showsSwitcher: .constant(false),
                    select: { reference in
                        if let editor = tabs.editors.first(where: { WorkspaceTabsModel.file($0.path) == reference }) {
                            tabs.select(editor.id)
                        }
                    }, close: { item in if let id = item.fileID { tabs.close(id) } },
                    rename: { _ in }, resetName: { _ in }, pin: { _ in }, move: { _, _ in },
                    drop: { _, _, _ in }, cancel: { _ in }, create: {}, reopen: {}, canReopen: false)
                if let editor = tabs.selected {
                    FileViewer(
                        path: editor.path, folder: editor.folder, failure: nil, isVisible: true,
                        openFile: { _ in }
                    ).environment(editor)
                } else {
                    ContentUnavailableView("Select a Source", systemImage: "doc.text.magnifyingglass")
                }
            }
        }
        .onAppear {
            model.isExpanded = true
            model.scope = .global
        }
        .modifier(MemoryLoading(folder: NSHomeDirectory(), model: model))
        .environment(client)
        .environment(tabs)
        .environment(browsers)
        .frame(width: 1000, height: 650)
    }
}

#Preview { MemoryViewPreview() }
