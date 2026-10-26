import Foundation

/// Sidebar visibility belongs to each folder's presentation, independent of its runtime.
struct SidebarPreferences {
    private static let key = "sidebarVisibilityByFolder"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = WorkflowLaunchPreferences.defaultStore()) {
        self.defaults = defaults
    }

    func isOpen(in folder: String) -> Bool {
        defaults.dictionary(forKey: Self.key)?[FolderWindows.canonicalPath(folder)] as? Bool ?? false
    }

    func remember(isOpen: Bool, in folder: String) {
        var saved = defaults.dictionary(forKey: Self.key) ?? [:]
        saved[FolderWindows.canonicalPath(folder)] = isOpen
        defaults.set(saved, forKey: Self.key)
    }
}
