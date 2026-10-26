import Foundation
import Testing

@testable import Handshake

struct SidebarPreferencesTests {
    @Test @MainActor func sharesVisibilityAcrossEquivalentFolderPaths() throws {
        let suite = "com.twineproject.Twine.tests.SidebarPreferencesTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appending(path: "SidebarPreferences-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appending(path: "folder")
        let alias = directory.appending(path: "alias")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: folder)

        let preferences = SidebarPreferences(defaults: defaults)
        preferences.remember(isOpen: true, in: alias.path)
        #expect(preferences.isOpen(in: folder.resolvingSymlinksInPath().path))
        preferences.remember(isOpen: false, in: folder.path)
        #expect(!preferences.isOpen(in: alias.path))
    }

    @Test @MainActor func defaultsClosedAndRestoresBothStatesIndependentlyByFolder() throws {
        let suite = "com.twineproject.Twine.tests.SidebarPreferencesTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = SidebarPreferences(defaults: defaults)
        #expect(!preferences.isOpen(in: "/first"))

        preferences.remember(isOpen: true, in: "/first")
        let reopened = SidebarPreferences(defaults: try #require(UserDefaults(suiteName: suite)))
        #expect(reopened.isOpen(in: "/first"))
        #expect(!reopened.isOpen(in: "/second"))

        reopened.remember(isOpen: true, in: "/second")
        reopened.remember(isOpen: false, in: "/first")
        let relaunched = SidebarPreferences(defaults: try #require(UserDefaults(suiteName: suite)))
        #expect(!relaunched.isOpen(in: "/first"))
        #expect(relaunched.isOpen(in: "/second"))
    }
}
