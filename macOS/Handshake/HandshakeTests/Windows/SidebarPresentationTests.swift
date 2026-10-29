import Foundation
import Testing

@testable import Handshake

@MainActor
struct SidebarPresentationTests {
    /// Short delays keep the timing logic under test without depending on the real ones.
    private func presentation() -> SidebarPresentation {
        SidebarPresentation(peekDelay: .milliseconds(40), closeDelay: .milliseconds(80))
    }

    @Test func restingOnTheRailPeeksAndLeavingReturnsToTheRail() async throws {
        let presentation = presentation()
        presentation.pointerEntered()
        #expect(presentation.overlay == .rail, "The peek waits for the pointer to rest")
        try await waitUntil { presentation.overlay == .peek }
        presentation.pointerExited()
        #expect(presentation.overlay == .peek, "Leaving forgives a short overshoot")
        try await waitUntil { presentation.overlay == .rail }
    }

    @Test func returningDuringTheGraceKeepsThePeek() async throws {
        let presentation = presentation()
        presentation.pointerEntered()
        try await waitUntil { presentation.overlay == .peek }
        presentation.pointerExited()
        presentation.pointerEntered()
        try await Task.sleep(for: .milliseconds(200))
        #expect(presentation.overlay == .peek)
    }

    @Test func aQuickClickOnTheRailDoesNotPeek() async throws {
        let presentation = presentation()
        presentation.pointerEntered()
        presentation.pressBegan()
        try await Task.sleep(for: .milliseconds(200))
        #expect(presentation.overlay == .rail)
    }

    @Test func anOpenMenuKeepsThePeekUntilThePointerHasLeft() async throws {
        let presentation = presentation()
        presentation.pointerEntered()
        try await waitUntil { presentation.overlay == .peek }
        presentation.menuTrackingChanged(isOpen: true)
        presentation.pointerExited()
        try await Task.sleep(for: .milliseconds(200))
        #expect(presentation.overlay == .peek)
        presentation.menuTrackingChanged(isOpen: false)
        try await waitUntil { presentation.overlay == .rail }
        presentation.pointerEntered()
        try await waitUntil { presentation.overlay == .peek }
        presentation.collapse()
        #expect(presentation.overlay == .rail)
    }

    @Test func monogramsUseASecondLetterOnlyWhenSessionsShareTheFirst() {
        let names = ["Board filters", "Release notes", "refactor", "  "]
        #expect(SessionMonogram.letters(for: "Board filters", among: names) == "B")
        #expect(SessionMonogram.letters(for: "Release notes", among: names) == "Rn")
        #expect(SessionMonogram.letters(for: "refactor", among: names) == "Re")
        #expect(SessionMonogram.letters(for: "  ", among: names) == "?")
    }

    @Test func onlyPeopleUpgradingFromTheTabBarSeeTheLayoutHint() throws {
        func defaults() throws -> UserDefaults {
            try #require(UserDefaults(suiteName: "SidebarPresentationTests-\(UUID())"))
        }
        let fresh = try defaults()
        TabLayout.prepareHint(in: fresh)
        #expect(fresh.bool(forKey: TabLayout.hintKey) == false)
        let upgraded = try defaults()
        upgraded.set(Data(), forKey: "tabManagement:/tmp/project")
        TabLayout.prepareHint(in: upgraded)
        #expect(upgraded.bool(forKey: TabLayout.hintKey))
        upgraded.set(false, forKey: TabLayout.hintKey)
        TabLayout.prepareHint(in: upgraded)
        #expect(upgraded.bool(forKey: TabLayout.hintKey) == false, "The hint is decided once")
        let chosen = try defaults()
        chosen.set(Data(), forKey: "tabManagement:/tmp/project")
        chosen.set(TabLayout.top.rawValue, forKey: TabLayout.storageKey)
        TabLayout.prepareHint(in: chosen)
        #expect(chosen.bool(forKey: TabLayout.hintKey) == false)
    }
}
