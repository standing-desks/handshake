import CoreGraphics

/// Owns selection reveals until measured geometry confirms visibility. User scrolling relinquishes ownership.
struct TabStripScrollState {
    struct Request: Equatable {
        let target: String
        let offset: CGFloat
    }

    struct Measurement: Equatable {
        let selected: String?
        let items: [String]
        let contentWidth: CGFloat
        let viewportWidth: CGFloat
        let offset: CGFloat
        /// Tab bounds in the padded, unscrolled content coordinate space.
        let frames: [String: CGRect]
        var isUserScrolling = false
    }

    private struct Layout: Equatable {
        let selected: String?
        let items: [String]
        let contentWidth: CGFloat
        let viewportWidth: CGFloat
        let targetFrame: CGRect?
    }

    private var layout: Layout?
    private(set) var pending: String?
    private var requestedOffset: CGFloat?

    var request: Request? {
        guard let pending, let requestedOffset else { return nil }
        return Request(target: pending, offset: requestedOffset)
    }

    mutating func update(_ measurement: Measurement) {
        let next = Layout(
            selected: measurement.selected, items: measurement.items,
            contentWidth: measurement.contentWidth, viewportWidth: measurement.viewportWidth,
            targetFrame: measurement.selected.flatMap { measurement.frames[$0] })
        if next != layout {
            layout = next
            pending = measurement.selected
            requestedOffset = nil
        }
        if measurement.isUserScrolling {
            pending = nil
            requestedOffset = nil
        }
        guard let pending, pending == measurement.selected, measurement.items.contains(pending),
            measurement.viewportWidth > 0, let frame = measurement.frames[pending], frame.width > 0,
            frame.maxX <= measurement.contentWidth + 0.5
        else { return }

        let visible = CGRect(x: measurement.offset, y: 0, width: measurement.viewportWidth, height: 1)
        let oversized = frame.width > visible.width
        let isVisible =
            oversized
            ? abs(frame.maxX - visible.maxX) <= 0.5 || abs(frame.minX - visible.minX) <= 0.5
            : frame.maxX <= visible.maxX + 0.5 && frame.minX >= visible.minX - 0.5
        if isVisible {
            self.pending = nil
            requestedOffset = nil
            return
        }

        let target: CGFloat
        let padding: CGFloat = oversized ? 0 : 1
        if pending == measurement.items.last || frame.maxX > visible.maxX {
            target = frame.maxX + padding - visible.width
        } else {
            target = frame.minX - padding
        }
        let offset = min(max(0, target), max(0, measurement.contentWidth - visible.width))
        guard abs(offset - measurement.offset) > 0.5, requestedOffset != offset else { return }
        requestedOffset = offset
    }
}
