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
    static let rowHeight: CGFloat = 32
    static let rowInset: CGFloat = 13
    static let rowFontSize: CGFloat = 12.5
    /// Tab rows sit one file-tree level inside their session.
    static let tabRowHeight: CGFloat = 32
    static let disclosureWidth: CGFloat = 20
    static let tabRowIndent: CGFloat = rowInset + disclosureWidth + 4 + 13
    static let monogramSize: CGFloat = 18
    /// The minimized sidebar: a rail of icons beside the content.
    static let railWidth: CGFloat = 52
    /// Holding a dragged tab over a collapsed session expands it after this long.
    static let springLoadDelay: Duration = .milliseconds(500)
}
