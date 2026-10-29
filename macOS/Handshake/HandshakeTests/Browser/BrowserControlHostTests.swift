import Foundation
import Testing

@testable import Handshake

@MainActor
struct BrowserControlHostTests {
    @Test func restartingWaitsForCancelledPollAndDiscardsItsJobs() async throws {
        let transport = DeferredBrowserTransport()
        let core = CoreClient(transport: transport)
        let browsers = BrowserTabsModel(selection: WorkspaceContentSelection())
        let host = BrowserControlHost(core: core, browsers: browsers)
        core.start()
        try await waitUntil { core.runState == .running }
        let first = Task { await host.run() }
        try await waitUntil { await transport.pollCount == 1 }
        first.cancel()
        let replacement = Task { await host.run() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await transport.pollCount == 1)
        let tabID = UUID().uuidString.lowercased()
        await transport.releasePoll(
            """
            {"active":["old"],"owners":{"\(tabID)":"old-session"},
             "jobs":[{"id":"old","session":"old-session","tab":"\(tabID)",
                      "action":{"action":"open","url":"https://example.test"}}]}
            """)
        await first.value
        try await waitUntil { await transport.pollCount == 2 }
        #expect(browsers.tabs.isEmpty)
        replacement.cancel()
        await transport.releasePoll()
        await replacement.value
        await core.stop()
    }
}
