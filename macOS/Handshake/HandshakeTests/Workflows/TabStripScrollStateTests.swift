import CoreGraphics
import Testing

@testable import Handshake

@MainActor
struct TabStripScrollStateTests {
    @Test func selectedTabLayoutChangesRevealItEvenWhenTotalContentSizeStaysTheSame() {
        var state = TabStripScrollState()
        state.update(
            .init(
                selected: "middle", items: ["middle", "last"], contentWidth: 600, viewportWidth: 400,
                offset: 0, frames: ["middle": CGRect(x: 201, y: 0, width: 132, height: 32)]))
        #expect(state.request?.offset == nil)
        #expect(state.pending == nil)
        state.update(
            .init(
                selected: "middle", items: ["middle", "last"], contentWidth: 600, viewportWidth: 400,
                offset: 0, frames: ["middle": CGRect(x: 201, y: 0, width: 220, height: 32)]))
        #expect(state.request?.offset == 22)
    }

    @Test func aTabWiderThanTheViewportCompletesAtItsTrailingEdge() {
        var state = TabStripScrollState()
        let frame = CGRect(x: 1, y: 0, width: 500, height: 32)
        state.update(
            .init(
                selected: "wide", items: ["wide"], contentWidth: 502, viewportWidth: 100, offset: 0,
                frames: ["wide": frame]))
        #expect(state.request?.offset == 401)
        state.update(
            .init(
                selected: "wide", items: ["wide"], contentWidth: 502, viewportWidth: 100, offset: 401,
                frames: ["wide": frame]))
        #expect(state.request?.offset == nil)
        #expect(state.pending == nil)
    }

    @Test func insertionThenSelectionRevealsTheNewTabUsingItsMeasuredBounds() {
        var state = TabStripScrollState()
        var measurement = TabStripScrollState.Measurement(
            selected: "third", items: ["third", "fourth"], contentWidth: 534, viewportWidth: 352, offset: 47,
            frames: ["third": CGRect(x: 267, y: 0, width: 132, height: 32)])
        state.update(measurement)
        #expect(state.request?.offset == nil)
        #expect(state.pending == nil)

        measurement = .init(
            selected: "fourth", items: measurement.items, contentWidth: 534, viewportWidth: 352, offset: 47,
            frames: measurement.frames)
        state.update(measurement)
        #expect(state.request?.offset == nil)
        #expect(state.pending == "fourth")

        measurement = .init(
            selected: "fourth", items: measurement.items, contentWidth: 534, viewportWidth: 352, offset: 47,
            frames: ["fourth": CGRect(x: 401, y: 0, width: 132, height: 32)])
        state.update(measurement)
        #expect(state.request?.offset == 182)
        #expect(state.pending == "fourth", "A request is not completed until the native viewport actually moves")
        let request = state.request
        measurement = .init(
            selected: "fourth", items: measurement.items, contentWidth: 534, viewportWidth: 352, offset: 47,
            frames: ["fourth": CGRect(x: 398, y: 0, width: 135, height: 32)])
        state.update(measurement)
        #expect(state.request?.offset == 182)
        #expect(state.request == request, "Equivalent layout measurements must not dispatch a second native command")
        measurement = .init(
            selected: "fourth", items: measurement.items, contentWidth: 534, viewportWidth: 352, offset: 182,
            frames: measurement.frames)
        state.update(measurement)
        #expect(state.request?.offset == nil)
        #expect(state.pending == nil)
        #expect(state.request == nil)
    }

    @Test func newSelectionSupersedesAnUnfinishedRevealAndWaitsForNativeContentSize() {
        var state = TabStripScrollState()
        let frames = [
            "third": CGRect(x: 267, y: 0, width: 132, height: 32),
            "fourth": CGRect(x: 401, y: 0, width: 132, height: 32),
        ]
        state.update(
            .init(
                selected: "third", items: ["third"], contentWidth: 400, viewportWidth: 352, offset: 0,
                frames: frames))
        #expect(state.request?.offset == 48)
        state.update(
            .init(
                selected: "fourth", items: ["third", "fourth"], contentWidth: 400, viewportWidth: 352,
                offset: 0, frames: frames))
        #expect(state.request?.offset == nil)
        #expect(state.pending == "fourth")
        state.update(
            .init(
                selected: "fourth", items: ["third", "fourth"], contentWidth: 534, viewportWidth: 352,
                offset: 0, frames: frames))
        #expect(state.request?.offset == 182)
    }

    @Test func manualScrollingCancelsRevealAndIdleDoesNotRestoreIt() {
        var state = TabStripScrollState()
        var measurement = TabStripScrollState.Measurement(
            selected: "last", items: ["first", "last"], contentWidth: 800, viewportWidth: 300, offset: 0,
            frames: ["last": CGRect(x: 650, y: 0, width: 149, height: 32)])
        state.update(measurement)
        #expect(state.request?.offset == 500)
        measurement.isUserScrolling = true
        state.update(measurement)
        #expect(state.request?.offset == nil)
        #expect(state.pending == nil)
        measurement.isUserScrolling = false
        state.update(measurement)
        #expect(state.request?.offset == nil)
        #expect(state.pending == nil)
    }

    @Test func viewportResizeRevealsSelectionWithoutChangingTheSelectedTab() {
        var state = TabStripScrollState()
        let frame = CGRect(x: 201, y: 0, width: 131, height: 32)
        state.update(
            .init(
                selected: "middle", items: ["middle", "last"], contentWidth: 600, viewportWidth: 400,
                offset: 0, frames: ["middle": frame]))
        #expect(state.request?.offset == nil)
        state.update(
            .init(
                selected: "middle", items: ["middle", "last"], contentWidth: 600, viewportWidth: 250,
                offset: 0, frames: ["middle": frame]))
        #expect(state.request?.offset == 83)
    }
}
