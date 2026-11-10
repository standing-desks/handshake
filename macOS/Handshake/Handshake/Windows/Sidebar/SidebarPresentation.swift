import OSLog
import Observation

private let sessionLogger = Logger(subsystem: "com.twineproject.Twine", category: "sessions")

/// Shared disclosure, scroll, and dialog state for the compact and expanded sidebar.
@Observable
final class SidebarPresentation {
    let railHover = SidebarRailHover()
    /// Sessions whose tabs show beneath them. The selected session joins when it changes.
    var expandedSessions: Set<UInt64> = []
    var isFilesExpanded = true
    var isSessionsExpanded = true
    /// The window presents dialogs so changing the sidebar width preserves them.
    var sessionToRename: CoreSession?
    var sessionToDelete: CoreSession?
    var tabToRename: WorkspaceTabItem?
    var failure: String?
    /// The first visible outline row, retained when changing between icons and titles.
    var scrollID: String?
    /// A selection change requests minimal scrolling to reveal this row.
    var revealID: String?

    /// Runs a sidebar action, showing and logging its failure.
    func run(_ operation: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await operation() } catch {
                failure = error.localizedDescription
                sessionLogger.error("Could not update session: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

}
