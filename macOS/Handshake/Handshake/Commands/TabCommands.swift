import SwiftUI

extension FocusedValues {
    @Entry var tabActions: TabActions?
}

struct TabActions {
    let moveSelection: (Int) -> Void
    let selectIndex: (Int) -> Void
    let showSwitcher: () -> Void
    let reopen: (() -> Void)?
    let rename: (() -> Void)?
    let pin: (() -> Void)?
    let move: ((Int) -> Void)?
    let closeTab: (() -> Void)?
    let closeTitle: String
    /// Every session's tabs for the toolbar's tab switcher, keyed by `WorkspaceTabItem.switcherKey`.
    var switcherItems: () -> [WorkspaceTabItem] = { [] }
    var switcherSelection: String?
    var selectSwitcherItem: (String) -> Void = { _ in }
}

struct TabCommands: Commands {
    let settings: SettingsPopup
    @FocusedValue(\.tabActions) private var focusedActions
    @FocusedValue(\.folderWindow) private var session
    @AppStorage(TabLayout.storageKey, store: WorkflowLaunchPreferences.defaultStore())
    private var tabLayout = TabLayout.defaultValue

    private var actions: TabActions? {
        settings.isPresented && settings.presentedWindowID == session?.id ? nil : focusedActions
    }

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Picker("Tab Layout", selection: $tabLayout) {
                Text("Tabs in Sidebar").tag(TabLayout.sidebar)
                Text("Tabs at the Top").tag(TabLayout.top)
            }
            .pickerStyle(.inline)
            if let actions {
                Divider()
                Button("Next Tab") { actions.moveSelection(1) }.keyboardShortcut(.tab, modifiers: .control)
                Button("Previous Tab") { actions.moveSelection(-1) }.keyboardShortcut(
                    .tab, modifiers: [.control, .shift])
                Button("Find Open Tab…", action: actions.showSwitcher).keyboardShortcut(
                    "a", modifiers: [.command, .shift])
                Menu("Go to Tab") {
                    ForEach(1...9, id: \.self) { index in
                        Button("Tab \(index)") { actions.selectIndex(index - 1) }
                            .keyboardShortcut(KeyEquivalent(Character(String(index))), modifiers: .command)
                    }
                }
                Button("Rename Tab…") { actions.rename?() }
                    .keyboardShortcut("i", modifiers: [.command, .shift]).disabled(actions.rename == nil)
                Button("Pin or Unpin Tab") { actions.pin?() }
                    .keyboardShortcut("p", modifiers: [.command, .shift]).disabled(actions.pin == nil)
                let isVertical = tabLayout == .sidebar
                Button(isVertical ? "Move Tab Up" : "Move Tab Left") { actions.move?(-1) }
                    .keyboardShortcut(isVertical ? .upArrow : .leftArrow, modifiers: [.command, .option, .shift])
                    .disabled(actions.move == nil)
                Button(isVertical ? "Move Tab Down" : "Move Tab Right") { actions.move?(1) }
                    .keyboardShortcut(isVertical ? .downArrow : .rightArrow, modifiers: [.command, .option, .shift])
                    .disabled(actions.move == nil)
            }
        }
        CommandGroup(after: .newItem) {
            if let actions {
                Button("Reopen Closed Tab") { actions.reopen?() }
                    .keyboardShortcut("t", modifiers: [.command, .shift]).disabled(actions.reopen == nil)
                Button("Close Tab") { actions.closeTab?() }
                    .keyboardShortcut("w", modifiers: [.command, .shift]).disabled(actions.closeTab == nil)
            }
        }
    }
}
