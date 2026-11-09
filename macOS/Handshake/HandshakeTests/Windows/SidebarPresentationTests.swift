import Foundation
import Testing

@testable import Handshake

@MainActor
struct SidebarPresentationTests {
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
