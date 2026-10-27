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
}

struct TabCommands: Commands {
    let settings: SettingsPopup
    @FocusedValue(\.tabActions) private var focusedActions
    @FocusedValue(\.folderWindow) private var session

    private var actions: TabActions? {
        settings.isPresented && settings.presentedWindowID == session?.id ? nil : focusedActions
    }

    var body: some Commands {
        CommandGroup(after: .sidebar) {
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
                Button("Move Tab Left") { actions.move?(-1) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option, .shift]).disabled(actions.move == nil)
                Button("Move Tab Right") { actions.move?(1) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option, .shift]).disabled(actions.move == nil)
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
