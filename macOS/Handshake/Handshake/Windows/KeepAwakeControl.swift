import OSLog
import SwiftUI

private let keepAwakeLogger = Logger(subsystem: "com.twineproject.Twine", category: "keep-awake")

/// Shares core's app-wide power state across folder windows.
@Observable
final class KeepAwakeModel {
    private(set) var isEnabled = false
    private(set) var isUpdating = false
    var failure: String?
    private let client: CoreClient
    private var monitor: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?
    private var updateGeneration = 0
    private var isStopping = false

    init(client: CoreClient) { self.client = client }

    var enabledBinding: Binding<Bool> {
        Binding(get: { self.isEnabled }, set: { enabled in Task { await self.update(enabled) } })
    }

    func start() {
        guard monitor == nil, !isStopping else { return }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                await self?.update(nil)
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    func update(_ enabled: Bool?) async {
        guard !isStopping, enabled != nil || updateTask == nil else { return }
        let preceding = updateTask
        updateGeneration += 1
        let generation = updateGeneration
        isUpdating = true
        let task = Task { [self] in
            await preceding?.value
            guard !isStopping else { return }
            await performUpdate(enabled)
        }
        updateTask = task
        await task.value
        if updateGeneration == generation {
            updateTask = nil
            isUpdating = false
        }
    }

    private func performUpdate(_ enabled: Bool?) async {
        do {
            let active = try await client.keepAwake(enabled)
            guard !isStopping else { return }
            if enabled == true, !active {
                failure = "Keep Awake couldn’t start. Please try again."
            } else if enabled == nil, isEnabled, !active {
                failure = "Keep Awake stopped unexpectedly. Turn it on again to retry."
            } else if enabled != nil {
                failure = nil
            }
            isEnabled = active
        } catch {
            guard !isStopping else { return }
            keepAwakeLogger.error("Keep Awake request failed: \(error.localizedDescription, privacy: .public)")
            failure = "The Keep Awake setting couldn’t be read or changed. Please try again."
        }
    }

    func stop() async {
        isStopping = true
        monitor?.cancel()
        await monitor?.value
        monitor = nil
        await updateTask?.value
        updateTask = nil
        isUpdating = false
        do { isEnabled = try await client.keepAwake(false) } catch {
            // caffeinate also watches the app PID, so quitting still releases its assertions.
            keepAwakeLogger.error("Keep Awake shutdown failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

struct KeepAwakeToolbar: ToolbarContent {
    /// The sidebar layout's toolbar buttons come first and bring their own spacer.
    var followsWorkspaceButtons = false

    var body: some ToolbarContent {
        if #available(macOS 26.1, *) {
            if !followsWorkspaceButtons { ToolbarSpacer(.flexible).visibilityPriority(.high) }
            item.visibilityPriority(.high)
        } else {
            if !followsWorkspaceButtons { ToolbarSpacer(.flexible) }
            item
        }
    }

    private var item: some ToolbarContent {
        ToolbarItem { KeepAwakeControl() }
    }
}

struct KeepAwakeControl: View {
    @Environment(KeepAwakeModel.self) private var model

    var body: some View {
        Toggle(isOn: model.enabledBinding) {
            Label("Keep Awake", systemImage: "cup.and.saucer")
        }
        .toggleStyle(.button)
        .labelStyle(.iconOnly)
        .disabled(model.isUpdating)
        .accessibilityIdentifier("keepAwake")
        .help(model.isEnabled ? "Turn off Keep Awake" : "Keep your Mac awake until you turn this off or quit Handshake")
    }
}
