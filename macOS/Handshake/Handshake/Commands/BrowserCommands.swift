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
    private var tab: BrowserTab? { available ? session?.browsers.selected : nil }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Browser Tab") { session?.browsers.create() }
                .keyboardShortcut("t", modifiers: [.command, .option]).disabled(!available)
        }
        CommandMenu("Browser") {
            Button("Open Location…") { tab?.locationRequest = UUID() }
                .keyboardShortcut("l").disabled(tab == nil)
            Button("Reload Page") { tab?.reload() }
                .keyboardShortcut("r").disabled(tab?.hasNavigated != true)
            Divider()
            Button("Back") { tab?.back() }.keyboardShortcut("[").disabled(tab?.canGoBack != true)
            Button("Forward") { tab?.forward() }.keyboardShortcut("]").disabled(tab?.canGoForward != true)
        }
    }
}
