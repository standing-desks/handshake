import OSLog
import SwiftUI

private let keepAwakeLogger = Logger(subsystem: "com.twineproject.Twine", category: "keep-awake")

/// All windows present the same core-owned power state, including when no folder is open.
@Observable
final class KeepAwakeModel {
    private(set) var isEnabled = false
    private(set) var isUpdating = false
    var failure: String?
    private let client: CoreClient
    private var monitor: Task<Void, Never>?
    private var request: Task<Bool, any Error>?
    private var isStopping = false

    init(client: CoreClient) { self.client = client }

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
        guard !isUpdating, !isStopping else { return }
        isUpdating = true
        let request = Task { try await client.keepAwake(enabled) }
        self.request = request
        defer {
            isUpdating = false
            self.request = nil
        }
        do {
            let active = try await request.value
            guard !isStopping else { return }
            if enabled == true, !active {
                failure = "Keep Awake couldn’t start. Please try again."
            } else if enabled == nil, isEnabled, !active {
                failure = "Keep Awake stopped unexpectedly. Turn it on again to retry."
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
        _ = await request?.result
        do { isEnabled = try await client.keepAwake(false) } catch {
            // caffeinate also watches the app PID, so quitting still releases its assertions.
            keepAwakeLogger.error("Keep Awake shutdown failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

struct KeepAwakeToolbar: ToolbarContent {
    weak var window: NSWindow?

    var body: some ToolbarContent {
        if #available(macOS 26.1, *) {
            ToolbarSpacer(.flexible).visibilityPriority(.high)
            item.visibilityPriority(.high)
        } else {
            ToolbarSpacer(.flexible)
            item
        }
    }

    private var item: some ToolbarContent {
        ToolbarItem { KeepAwakeControl(window: window) }
    }
}

struct KeepAwakeControl: View {
    @Environment(KeepAwakeModel.self) private var model
    @Environment(\.controlActiveState) private var activeState
    @State private var failure: String?
    weak var window: NSWindow?

    var body: some View {
        Button {
            Task { await model.update(!model.isEnabled) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: model.isEnabled ? "cup.and.saucer.fill" : "cup.and.saucer")
                Text("Keep Awake")
                Text(model.isEnabled ? "On" : "Off").foregroundStyle(.secondary)
            }
            .foregroundStyle(model.isEnabled ? Color.accentColor : .secondary)
        }
        .tint(model.isEnabled ? Color.accentColor : nil)
        .disabled(model.isUpdating)
        .accessibilityLabel("Keep Awake")
        .accessibilityValue(model.isEnabled ? "On" : "Off")
        .accessibilityIdentifier("keepAwake")
        .help(model.isEnabled ? "Turn off Keep Awake" : "Keep your Mac awake until you turn this off or quit Handshake")
        .onChange(of: model.failure, initial: true) { _, _ in presentFailure() }
        .onChange(of: activeState) { _, _ in presentFailure() }
        .alert(
            "Keep Awake",
            isPresented: Binding(
                get: { failure != nil }, set: { if !$0 { failure = nil } })
        ) {
            Button("OK") { failure = nil }
        } message: {
            Text(failure ?? "")
        }
    }

    private func presentFailure() {
        guard window?.isKeyWindow == true, let message = model.failure else { return }
        failure = message
        model.failure = nil
    }
}
