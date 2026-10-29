import Foundation

/// Where folder windows show their tabs. An app-wide presentation preference, kept out of core.
nonisolated enum TabLayout: String, CaseIterable, Sendable {
    /// Each session lists its tabs in the sidebar, and the window has no tab bar.
    case sidebar
    /// One tab bar above the terminal panel shows the selected session's tabs.
    case top

    static let storageKey = "tabLayout"
    static let defaultValue = TabLayout.sidebar
    /// Whether the toolbar still explains the move to the sidebar layout.
    static let hintKey = "tabLayoutHint"

    /// People upgrading from the tab bar see a one-time hint. Decided once, on the first launch with this
    /// preference: earlier tab arrangements mean the person used the tab bar.
    static func prepareHint(in defaults: UserDefaults) {
        guard defaults.object(forKey: hintKey) == nil else { return }
        let upgraded =
            defaults.object(forKey: storageKey) == nil
            && defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix("tabManagement:") }
        defaults.set(upgraded, forKey: hintKey)
    }

    var toggleTitle: String { self == .sidebar ? "Show Tabs at the Top" : "Show Tabs in the Sidebar" }
    var toggled: TabLayout { self == .sidebar ? .top : .sidebar }
}
