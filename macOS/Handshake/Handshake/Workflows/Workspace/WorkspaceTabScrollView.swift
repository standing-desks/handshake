import AppKit
import SwiftUI

/// The native container measures its document and reveals a tab in the same layout pass.
/// SwiftUI renders the controls, but does not feed asynchronous widths back into this viewport.
struct WorkspaceTabScrollView<Content: View>: NSViewControllerRepresentable {
    let viewport: WorkspaceTabViewport
    let selected: String?
    let references: [String]
    let isDragging: Bool
    let coordinateSpace: String
    @ViewBuilder let content: Content

    func makeNSViewController(context: Context) -> WorkspaceTabScrollController {
        WorkspaceTabScrollController(viewport: viewport)
    }

    func updateNSViewController(_ controller: WorkspaceTabScrollController, context: Context) {
        viewport.configure(selected: selected, references: references, isDragging: isDragging)
        controller.viewportScale = context.environment.appZoom?.scale ?? 1
        controller.setContent(
            AnyView(
                content
                    .appZoom()
                    .coordinateSpace(name: coordinateSpace)
                    .environment(\.appZoom, context.environment.appZoom)
                    .environment(\.colorScheme, context.environment.colorScheme)
                    .environment(\.effectiveReduceMotion, context.environment.effectiveReduceMotion)
                    .environment(\.locale, context.environment.locale)
                    .environment(\.layoutDirection, context.environment.layoutDirection)))
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsViewController controller: WorkspaceTabScrollController, context: Context
    ) -> CGSize? {
        let ideal = controller.documentSize
        let width = ideal.width / controller.viewportScale
        return CGSize(width: min(proposal.width ?? width, width), height: WorkflowTabLayout.height)
    }
}

final class WorkspaceTabScrollController: NSViewController {
    let viewport: WorkspaceTabViewport
    private let host = NSHostingController(rootView: AnyView(EmptyView()))
    private let scroll = WorkspaceTabNativeScrollView()
    private lazy var container = RetainedContentHost(content: scroll, responder: scroll)

    var viewportScale: CGFloat = 1 {
        didSet {
            container.viewportScale = viewportScale
            view.needsLayout = true
        }
    }

    init(viewport: WorkspaceTabViewport) {
        self.viewport = viewport
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = container
        container.focusesOnShow = false
        container.viewportScale = viewportScale
        container.setVisible(true)
        host.sizingOptions = []
        addChild(host)
        scroll.documentView = host.view
        scroll.viewport = viewport
        viewport.scrollView = scroll
        scroll.layoutDocument = { [weak self] in self?.layoutDocument() }
    }

    var documentSize: CGSize {
        host.sizeThatFits(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
    }

    func setContent(_ content: AnyView) {
        host.rootView = content
        // Selection can change without changing any document frames.
        scroll.needsLayout = true
        view.needsLayout = true
        view.invalidateIntrinsicContentSize()
    }

    private func layoutDocument() {
        let size = documentSize
        let frame = CGRect(origin: .zero, size: size)
        if host.view.frame != frame { host.view.frame = frame }
        host.view.layoutSubtreeIfNeeded()
        viewport.documentDidLayout()
    }
}

private final class WorkspaceTabNativeScrollView: NSScrollView {
    weak var viewport: WorkspaceTabViewport?
    var layoutDocument: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        borderType = .noBorder
        drawsBackground = false
        hasHorizontalScroller = false
        hasVerticalScroller = false
        automaticallyAdjustsContentInsets = false
        horizontalScrollElasticity = .none
        verticalScrollElasticity = .none
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        layoutDocument?()
    }

    override func scrollWheel(with event: NSEvent) {
        viewport?.userDidScroll()
        super.scrollWheel(with: event)
    }
}

/// Presentation state tied to the real document/clip pair, including native target rectangles.
final class WorkspaceTabViewport {
    weak var scrollView: NSScrollView?
    private var targets: [String: WeakTarget] = [:]
    private var selected: String?
    private var references: [String] = []
    private var pending = false
    private var userOwnsPosition = false
    private var geometry: Geometry?

    private struct WeakTarget { weak var view: NSView? }
    private struct Geometry: Equatable {
        let document: CGSize
        let viewport: CGSize
        let target: CGRect
    }

    var visibleRect: CGRect { scrollView?.documentVisibleRect ?? .zero }

    func configure(selected: String?, references: [String], isDragging: Bool) {
        if self.selected != selected {
            userOwnsPosition = false
            pending = selected != nil
        } else if self.references != references, !userOwnsPosition {
            pending = selected != nil
        }
        self.selected = selected
        self.references = references
        if isDragging { userDidScroll() }
    }

    func register(_ view: NSView, reference: String) {
        targets[reference] = WeakTarget(view: view)
        scrollView?.needsLayout = true
    }

    func unregister(_ view: NSView, reference: String) {
        if targets[reference]?.view === view { targets.removeValue(forKey: reference) }
    }

    func frame(for reference: String) -> CGRect? {
        guard let view = targets[reference]?.view, let document = scrollView?.documentView,
            view.isDescendant(of: document)
        else { return nil }
        return view.convert(view.bounds, to: document)
    }

    func userDidScroll() {
        userOwnsPosition = true
        pending = false
    }

    func reveal(_ reference: String) {
        guard let document = scrollView?.documentView, let frame = frame(for: reference), frame.width > 0 else {
            return
        }
        var rect = frame.insetBy(dx: -1, dy: 0)
        rect.origin.y = visibleRect.minY
        rect.size.height = visibleRect.height
        document.scrollToVisible(rect)
    }

    func documentDidLayout() {
        guard let scrollView, let document = scrollView.documentView, let selected,
            let target = frame(for: selected), target.width > 0, scrollView.contentSize.width > 0
        else { return }
        let next = Geometry(document: document.bounds.size, viewport: visibleRect.size, target: target)
        if geometry != next, !userOwnsPosition { pending = true }
        geometry = next
        guard pending, !userOwnsPosition else { return }
        // A native target cannot be revealed until its document has incorporated that layout.
        guard target.maxX <= document.bounds.maxX + 0.5 else { return }
        reveal(selected)
        let visible = visibleRect
        pending =
            target.width <= visible.width
            ? target.minX < visible.minX - 0.5 || target.maxX > visible.maxX + 0.5
            : abs(target.minX - visible.minX) > 1 && abs(target.maxX - visible.maxX) > 1
    }
}

/// A native rectangle for the SwiftUI tab, without an asynchronous geometry callback.
struct WorkspaceTabScrollTarget: NSViewRepresentable {
    let viewport: WorkspaceTabViewport
    let reference: String

    func makeNSView(context: Context) -> TargetView { TargetView() }

    func updateNSView(_ view: TargetView, context: Context) {
        view.viewport = viewport
        view.reference = reference
        viewport.register(view, reference: reference)
    }

    static func dismantleNSView(_ view: TargetView, coordinator: ()) {
        view.viewport?.unregister(view, reference: view.reference)
    }

    final class TargetView: NSView {
        weak var viewport: WorkspaceTabViewport?
        var reference = ""

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func setFrameSize(_ newSize: NSSize) {
            let changed = frame.size != newSize
            super.setFrameSize(newSize)
            if changed { viewport?.scrollView?.needsLayout = true }
        }
    }
}
