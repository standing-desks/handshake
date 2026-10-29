import Foundation
import OSLog

private let browserLogger = Logger(subsystem: "com.twineproject.Twine", category: "browser-control")

/// Connects a window's core-owned requests to its retained WebKit pages.
@MainActor
final class BrowserControlHost {
    private let core: CoreClient
    private let browsers: BrowserTabsModel
    private var tasks: [String: Task<Void, Never>] = [:]
    private var requests: [String: BrowserJob] = [:]
    private var stopped: Set<String> = []
    private var queue: [BrowserJob] = []
    private var isRunning = false

    init(core: CoreClient, browsers: BrowserTabsModel) {
        self.core = core
        self.browsers = browsers
    }

    func run() async {
        // SwiftUI can start the replacement task before a cancelled poll has returned.
        while isRunning {
            do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
        }
        guard !Task.isCancelled else { return }
        isRunning = true
        defer {
            isRunning = false
            for task in tasks.values { task.cancel() }
            tasks.removeAll()
            requests.removeAll()
            queue.removeAll()
            for tab in browsers.tabs {
                if tab.controlOwner != nil { tab.stop() }
                tab.controlOwner = nil
                tab.stopControl = nil
                tab.controlDidClose = nil
            }
        }
        do {
            try await core.waitUntilRunning()
            while !Task.isCancelled {
                let state = try await core.browserControl(.init(action: "poll"))
                try Task.checkCancellation()
                apply(state)
                try await Task.sleep(for: .milliseconds(50))
            }
        } catch {
            if !Task.isCancelled, core.runState == .running, !core.isStopping {
                browserLogger.error("Browser control stopped after a core communication failure.")
            }
        }
    }

    private func apply(_ state: BrowserControlState) {
        let active = Set(state.active ?? [])
        for (id, task) in tasks where !active.contains(id) {
            task.cancel()
            tasks.removeValue(forKey: id)
            requests.removeValue(forKey: id)
        }
        for tab in browsers.tabs {
            let owner = state.owners?[tab.id.uuidString.lowercased()]
            let current = owner.flatMap { stopped.contains($0) ? nil : $0 }
            if tab.controlOwner != nil, current == nil { tab.stop() }
            tab.controlOwner = current
            tab.stopControl = { [weak self, weak tab] in
                guard let self, let tab, let owner = tab.controlOwner else { return }
                stop(owner)
            }
        }
        queue.append(contentsOf: state.jobs ?? [])
        queue.removeAll { !active.contains($0.id) || stopped.contains($0.session) }
        if tasks.isEmpty, !queue.isEmpty {
            let job = queue.removeFirst()
            requests[job.id] = job
            tasks[job.id] = Task { [weak self] in await self?.execute(job) }
        }
    }

    private func stop(_ session: String) {
        stopped.insert(session)
        for (id, task) in tasks where requests[id]?.session == session { task.cancel() }
        for tab in browsers.tabs where tab.controlOwner == session {
            tab.controlOwner = nil
            tab.stop()
        }
        Task { await send(.init(action: "stop", session: session)) }
    }

    private func closed(_ tab: String) {
        for (id, task) in tasks where requests[id]?.tab == tab { task.cancel() }
        queue.removeAll { $0.tab == tab }
        Task { await send(.init(action: "closed", tab: tab)) }
    }

    private func send(_ command: BrowserHostCommand) async {
        do {
            _ = try await core.browserControl(command)
        } catch {
            if core.runState == .running, !core.isStopping {
                browserLogger.error("Browser command could not reach core.")
            }
        }
    }

    private func execute(_ job: BrowserJob) async {
        defer {
            tasks.removeValue(forKey: job.id)
            requests.removeValue(forKey: job.id)
        }
        let result: BrowserControlResult
        do {
            try Task.checkCancellation()
            if job.action.action == "list" {
                let tabs = browsers.tabs.filter { $0.controlOwner == job.session }.map {
                    ["id": $0.id.uuidString.lowercased(), "title": $0.title, "url": $0.address]
                }
                result = .init(success: true, content: String(data: try JSONEncoder().encode(tabs), encoding: .utf8))
            } else {
                guard let id = UUID(uuidString: job.tab) else {
                    throw BrowserAutomationError.unavailable("Invalid tab ID.")
                }
                let tab: BrowserTab
                if job.action.action == "open" {
                    tab = browsers.createControlled(id: id)
                    tab.controlOwner = job.session
                    tab.stopControl = { [weak self] in self?.stop(job.session) }
                    tab.controlDidClose = { [weak self] in self?.closed(job.tab) }
                } else {
                    guard let existing = browsers.tabs.first(where: { $0.id == id }) else {
                        _ = try await core.browserControl(.init(action: "closed", tab: job.tab))
                        throw BrowserAutomationError.unavailable("The browser tab was closed.")
                    }
                    tab = existing
                }
                if job.action.action == "close" {
                    tab.controlDidClose = nil
                    browsers.close(id)
                    result = .init(success: true)
                } else {
                    browsers.select(id)
                    result = try await BrowserAutomationDriver(tab: tab).execute(job.action)
                }
            }
        } catch {
            result = .init(
                success: false,
                error: .init(
                    code: error is CancellationError ? "cancelled" : "browser_error",
                    message: error.localizedDescription))
        }
        await send(.init(action: "complete", id: job.id, result: result))
    }
}
