import Foundation
import Observation

/// One content surface owns keyboard focus; the workflow selection is retained separately.
@Observable
final class WorkspaceContentSelection {
    enum Content: Equatable {
        case file(UUID)
        case browser(UUID)
    }
    private(set) var content: Content?
    private(set) var generation = UUID()

    /// Session navigation keeps a browser active and invalidates pending file navigation.
    func showSession() {
        if case .browser = content { select(content) } else { select(nil) }
    }

    func select(_ content: Content?) {
        self.content = content
        generation = UUID()
    }
}
