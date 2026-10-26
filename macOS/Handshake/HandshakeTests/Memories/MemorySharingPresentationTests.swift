import Foundation
import Testing

@testable import Handshake

struct MemorySharingPresentationTests {
    @Test func nativeProfilesPreserveExistingAdapterBindings() {
        let snapshot = HandshakeMemorySnapshot(
            enabled: true, folder: "/project", storePath: "/store", amisPath: "/library.amis.json",
            claudePath: "/native/claude", codexPath: "/native/codex", records: [], status: "sharing",
            message: "Delivered.", lastSync: nil, modelCalls: 0)
        #expect(snapshot.sharingProfiles.map(\.id) == ["claude_code", "codex"])
        #expect(snapshot.sharingProfiles.map(\.path) == ["/native/claude", "/native/codex"])
    }

    @Test func agentSummaryAcceptsAdditionalProfilesWithoutPairSpecificCopy() {
        let profiles = [
            MemorySharingProfile(id: "one", name: "Agent One", path: "/one"),
            MemorySharingProfile(id: "two", name: "Agent Two", path: "/two"),
            MemorySharingProfile(id: "three", name: "Agent Three", path: "/three"),
        ]
        let summary = MemorySharingProfile.names(profiles)
        #expect(profiles.allSatisfy { summary.contains($0.name) })
        #expect(!summary.contains("Codex"))
        #expect(!summary.contains("Claude"))
    }

    @Test func duplicatePreviewHeadingIsPresentationOnly() {
        let source = "# Trial account\n\nUse maple-417."
        let record = HandshakeMemorySummary(id: "one", title: "Trial account", sources: 1, preview: source)
        #expect(record.sharingPreview == "Use maple-417.")
        #expect(record.preview == source)
    }

    @Test func distinctHeadingAndPlainTextArePreserved() {
        let heading = HandshakeMemorySummary(
            id: "one", title: "Account", sources: 1, preview: "# Important constraint\nUse maple-417.")
        let plain = HandshakeMemorySummary(id: "two", title: "Account", sources: 1, preview: "Use maple-417.")
        #expect(heading.sharingPreview == heading.preview)
        #expect(plain.sharingPreview == plain.preview)
    }
}
