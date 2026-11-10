import AppKit
import SwiftUI
import Testing

@testable import Handshake

@MainActor
struct WorkspaceTabViewportTests {
    @Test func growingTheDocumentRevealsEachNewSelectionWithoutReplacingIt() async {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.showTabs(count: 1, selected: 0)
        #expect(await fixture.settle { fixture.isVisible(0) }, "\(fixture.geometry)")
        let document = fixture.viewport.scrollView?.documentView
        for count in 2...8 {
            fixture.showTabs(count: count, selected: count - 1)
            #expect(await fixture.settle { fixture.isVisible(count - 1) })
            #expect(fixture.viewport.scrollView?.documentView === document)
        }
    }

    @Test func userScrollingSurvivesLayoutUntilAnotherTabIsSelected() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.showTabs(count: 8, selected: 7)
        #expect(await fixture.settle { fixture.isVisible(7) })
        let scroll = try #require(fixture.viewport.scrollView)
        fixture.viewport.userDidScroll()
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        fixture.controller.view.needsLayout = true
        #expect(await fixture.settle { abs(fixture.viewport.visibleRect.minX) < 0.5 })
        #expect(!fixture.isVisible(7))
        fixture.showTabs(count: 8, selected: 0)
        #expect(await fixture.settle { fixture.isVisible(0) })
        fixture.showTabs(count: 8, selected: 7)
        #expect(await fixture.settle { fixture.isVisible(7) })
    }

    @Test func resizingUsesTheActualNativeViewport() async {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.showTabs(count: 8, selected: 7)
        #expect(await fixture.settle { fixture.isVisible(7) })
        for width in [270.0, 520.0, 300.0] {
            fixture.window.setContentSize(CGSize(width: width, height: 32))
            #expect(await fixture.settle { fixture.isVisible(7) })
            #expect(abs(fixture.viewport.visibleRect.width - width) < 0.5)
        }
    }

    @MainActor private final class Fixture {
        let viewport = WorkspaceTabViewport()
        let controller: WorkspaceTabScrollController
        let window: NSWindow

        init() {
            controller = WorkspaceTabScrollController(viewport: viewport)
            window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 400, height: 32), styleMask: .borderless,
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = controller
            window.setContentSize(CGSize(width: 400, height: 32))
            window.orderBack(nil)
        }

        var geometry: String {
            let target = viewport.frame(for: "0")
            return "window=\(window.contentLayoutRect) native=\(controller.view.frame) "
                + "document=\(String(describing: viewport.scrollView?.documentView?.frame)) "
                + "visible=\(viewport.visibleRect) target=\(String(describing: target))"
        }

        func showTabs(count: Int, selected: Int) {
            let viewport = viewport
            viewport.configure(selected: String(selected), references: (0..<count).map(String.init), isDragging: false)
            controller.setContent(
                AnyView(
                    HStack(spacing: 6) {
                        ForEach(0..<count, id: \.self) { index in
                            Text("Tab \(index)").frame(width: 132, height: 32)
                                .background(WorkspaceTabScrollTarget(viewport: viewport, reference: String(index)))
                        }
                    }
                    .padding(.horizontal, 1)
                    .fixedSize(horizontal: true, vertical: false)))
        }

        func isVisible(_ index: Int) -> Bool {
            guard let frame = viewport.frame(for: String(index)), frame.width > 0 else { return false }
            let visible = viewport.visibleRect
            return frame.minX >= visible.minX - 0.5 && frame.maxX <= visible.maxX + 0.5
        }

        func settle(until condition: () -> Bool) async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(2))
            repeat {
                controller.view.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(10))
            } while clock.now < deadline
            return false
        }

        func close() { window.close() }
    }
}
