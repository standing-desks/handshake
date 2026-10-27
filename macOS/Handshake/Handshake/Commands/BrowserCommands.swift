import SwiftUI

struct BrowserCommands: Commands {
    let settings: SettingsPopup
    @FocusedValue(\.folderWindow) private var session
    private var available: Bool {
        guard let session else { return false }
        return !session.isClosing && session.coreClient.runState == .running
            && session.coreClient.snapshot?.folders.openFolder != nil
            && settings.presentedWindowID != session.id
    }
    private var tab: BrowserTab? {
        guard available, let selected = session?.browsers.selected, !selected.hasNativeSheet else { return nil }
        return selected
    }

    private func shortcut(_ key: KeyEquivalent) -> KeyboardShortcut? {
        tab.map { _ in KeyboardShortcut(key) }
    }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Browser Tab") { session?.browsers.create() }
                .keyboardShortcut("t", modifiers: [.command, .option]).disabled(!available)
        }
        CommandMenu("Browser") {
            Button("Open Location…") { tab?.locationRequest = UUID() }
                .keyboardShortcut(shortcut("l")).disabled(tab == nil)
            Button("Reload Page") { tab?.reload() }
                .keyboardShortcut(shortcut("r")).disabled(tab?.hasNavigated != true)
            Divider()
            Button("Back") { tab?.back() }.keyboardShortcut(shortcut("[")).disabled(tab?.canGoBack != true)
            Button("Forward") { tab?.forward() }.keyboardShortcut(shortcut("]")).disabled(tab?.canGoForward != true)
        }
    }
}
