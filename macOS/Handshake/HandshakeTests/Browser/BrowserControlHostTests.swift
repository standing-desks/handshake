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
             "jobs":[{"id":"old","session":"old-session","terminal":1,"tab":"\(tabID)",
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

    @Test func aPageAnAgentOpensBelongsToItsTerminalsSession() async throws {
        var snapshot = CoreSnapshot.testReady()
        snapshot.workflows.workflows = [
            try JSONDecoder().decode(
                CoreWorkflow.self,
                from: Data(
                    """
                    {"workflowId":4,"sessionId":2,"name":"Agent","kind":"singleAgent","terminalId":9,
                     "agents":[],"status":"running","startedAt":1,"endedAt":null,"restored":false}
                    """.utf8))
        ]
        let transport = DeferredBrowserTransport(snapshot: snapshot)
        let core = CoreClient(transport: transport)
        let browsers = BrowserTabsModel(selection: WorkspaceContentSelection())
        let host = BrowserControlHost(core: core, browsers: browsers)
        core.start()
        try await waitUntil { core.runState == .running }
        let running = Task { await host.run() }
        try await waitUntil { await transport.pollCount == 1 }
        await transport.releasePoll(
            """
            {"active":["open"],"jobs":[{"id":"open","session":"Terminal 9","terminal":9,
              "tab":"\(UUID().uuidString.lowercased())","action":{"action":"open","url":"about:blank"}}]}
            """)
        try await waitUntil { !browsers.tabs.isEmpty }
        #expect(browsers.tabs.first?.agentSession == 2)
        #expect(browsers.selection.content == nil)
        try await waitUntil { await transport.pollCount == 2 }
        running.cancel()
        await transport.releasePoll()
        await running.value
        await core.stop()
    }
}
