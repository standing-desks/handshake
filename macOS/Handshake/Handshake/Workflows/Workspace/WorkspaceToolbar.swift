import SwiftUI

/// The tab bar's buttons, in the toolbar beside Keep Awake when the sidebar shows the tabs.
struct WorkspaceToolbar: ToolbarContent {
    let model: WorkspaceTabsModel
    /// The selected session's tab count, from this window's own state so inactive windows show it too.
    let tabCount: Int

    var body: some ToolbarContent {
        ToolbarSpacer(.flexible)
        // As the window narrows, the split buttons overflow first; the tab buttons stay with Keep Awake.
        if #available(macOS 26.1, *) {
            ToolbarItemGroup { WorkspaceSplitButtons() }.visibilityPriority(.low)
            ToolbarSpacer(.fixed)
            ToolbarItemGroup { WorkspaceTabButtons(model: model, tabCount: tabCount) }.visibilityPriority(.high)
        } else {
            ToolbarItemGroup { WorkspaceSplitButtons() }
            ToolbarSpacer(.fixed)
            ToolbarItemGroup { WorkspaceTabButtons(model: model, tabCount: tabCount) }
        }
        ToolbarSpacer(.fixed)
    }
}

private struct WorkspaceSplitButtons: View {
    @FocusedValue(\.workflowActions) private var actions

    var body: some View {
        Button("Split Right", systemImage: "rectangle.split.2x1") { actions?.splitTerminal?(.right) }
            .help("Split Right (⌘D)")
            .accessibilityIdentifier("splitTerminalRight")
            .disabled(actions?.splitTerminal == nil)
        Button("Split Down", systemImage: "rectangle.split.1x2") { actions?.splitTerminal?(.down) }
            .help("Split Down (⇧⌘D)")
            .accessibilityIdentifier("splitTerminalDown")
            .disabled(actions?.splitTerminal == nil)
    }
}

private struct WorkspaceTabButtons: View {
    @FocusedValue(\.workflowActions) private var workflowActions
    @FocusedValue(\.tabActions) private var tabActions
    @Environment(BrowserTabsModel.self) private var browsers
    @Bindable var model: WorkspaceTabsModel
    let tabCount: Int

    var body: some View {
        Button("New Workflow", systemImage: "plus") { workflowActions?.create() }
            .help("New Workflow (⌘T)")
            .accessibilityIdentifier("newWorkflow")
            .disabled(workflowActions == nil)
        Button("New Browser Tab", systemImage: "globe") { browsers.create() }
            .help("New Browser Tab (⌥⌘T)")
            .accessibilityIdentifier("newBrowserTab")
        Button {
            model.showsSwitcher.toggle()
        } label: {
            Label("\(tabCount)", systemImage: "chevron.down").labelStyle(.titleAndIcon)
        }
        .help("Find an Open Tab (⇧⌘A)")
        .accessibilityLabel("Find an open tab, \(tabCount) tabs")
        .accessibilityIdentifier("tabSwitcher")
        .popover(isPresented: $model.showsSwitcher) {
            // The switcher opens in the active window, which publishes every session's tabs.
            WorkspaceTabSwitcher(
                items: tabActions?.switcherItems() ?? [], selected: tabActions?.switcherSelection,
                select: { tabActions?.selectSwitcherItem($0) }
            )
            .appZoom()
        }
    }
}
