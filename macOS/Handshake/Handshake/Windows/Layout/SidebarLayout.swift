import SwiftUI

nonisolated enum SidebarLayout {
    /// Keep section headers and memory controls reachable by scrolling in short windows.
    static let minimumContentHeight: CGFloat = 400
    static let minimumWidth: CGFloat = 245
    static let idealWidth: CGFloat = 285
    static let maximumWidth: CGFloat = 325
    static let contentInset: CGFloat = 10
    static let sectionHeaderHeight: CGFloat = 48
    static let sectionHeaderPadding: CGFloat = 17
    static let rowHeight: CGFloat = 27
    static let rowInset: CGFloat = 13
    static let rowFontSize: CGFloat = 12.5
    /// Tab rows sit one file-tree level inside their session.
    static let tabRowHeight: CGFloat = 26
    static let tabRowIndent: CGFloat = rowInset + 11 + 4 + 13
    static let monogramSize: CGFloat = 18
    /// The minimized sidebar: a rail of icons beside the content.
    static let railWidth: CGFloat = 52
    static let railInset: CGFloat = 8
    static let overlayCornerRadius: CGFloat = 16
    /// Resting on the rail this long opens the peek; a quick click on a rail icon selects without expanding.
    static let peekDelay: Duration = .milliseconds(250)
    /// After the pointer leaves the peek, it closes after this long.
    static let peekCloseDelay: Duration = .milliseconds(300)
    /// Holding a dragged tab over a collapsed session expands it after this long.
    static let springLoadDelay: Duration = .milliseconds(500)
}
