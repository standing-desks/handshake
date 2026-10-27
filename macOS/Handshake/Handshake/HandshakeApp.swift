//
//  HandshakeApp.swift
//  Handshake
//
//  Created by Aravind Nidadavolu on 9/26/26.
//

import AppKit
import Foundation
import SwiftUI

@main
struct HandshakeApp: App {
    @NSApplicationDelegateAdaptor(AppTerminationDelegate.self) private var terminationDelegate
    @State private var initialWindowID = UUID()
    @State private var startup = AppStartup()

    init() {
        // Each folder has its own window and runtime.
        NSWindow.allowsAutomaticWindowTabbing = false
        #if DEBUG
            // Configure the core before starting any runtimes. Explicit environment overrides still apply.
            let environment = ProcessInfo.processInfo.environment
            let configOverride = environment["HANDSHAKE_CONFIG_PATH"] ?? environment["TWINE_CONFIG_PATH"]
            if configOverride == nil && environment["XDG_CONFIG_HOME"] == nil {
                setenv("HANDSHAKE_CONFIG_PATH", Self.dataDirectory.appending(path: "config/config.toml").path, 1)
            }
            // UI tests exercise both appearances without changing the desktop's appearance.
            switch ProcessInfo.processInfo.environment["HANDSHAKE_TEST_APPEARANCE"] {
            case "Light":
                NSApplication.shared.appearance = NSAppearance(named: .aqua)
            case "Dark":
                NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
            default:
                break
            }
        #endif
    }

    var body: some Scene {
        WindowGroup(id: "folder", for: UUID.self) { id in
            Group {
                switch startup.state {
                case .waiting, .preparing:
                    Color.clear
                case .failed(let message):
                    ContentUnavailableView(
                        "Handshake Couldn't Start", systemImage: "exclamationmark.triangle", description: Text(message))
                case .ready(let presentation):
                    FolderWindowRoot(id: id.wrappedValue ?? initialWindowID, windows: presentation.windows)
                        .environment(presentation.settings)
                        .environment(presentation.keepAwake)
                        .defaultAppStorage(WorkflowLaunchPreferences.defaultStore())
                        .environment(presentation.layouts)
                        .environment(presentation.harnessModels)
                        .environment(\.appZoom, presentation.zoom)
                        .task {
                            presentation.keepAwake.start()
                            presentation.zoom.installKeyboardShortcuts()
                            terminationDelegate.attach(
                                windows: presentation.windows, layouts: presentation.layouts,
                                settings: presentation.settings, keepAwake: presentation.keepAwake)
                        }
                }
            }
            .task { await startup.prepare() }
        }
        .windowToolbarStyle(.unified)
        .defaultWindowPlacement { _, context in
            let available = context.defaultDisplay.visibleRect.size
            let size = CGSize(width: available.width * 0.8, height: available.height * 0.85)
            return WindowPlacement(size: size)
        }
        .restorationBehavior(.disabled)
        .commands {
            SidebarCommands()
            UpdateCommands()
            if case .ready(let presentation) = startup.state {
                FolderCommands(windows: presentation.windows, settings: presentation.settings)
                BrowserCommands(settings: presentation.settings)
                TabCommands(settings: presentation.settings)
                AppZoomCommands(zoom: presentation.zoom)
            }
        }
    }

    private static var dataDirectory: URL { AppPaths.dataDirectory }

}
