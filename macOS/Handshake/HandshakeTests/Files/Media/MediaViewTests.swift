import AVKit
import AppKit
import SwiftUI
import Testing

@testable import Handshake

@MainActor
struct MediaViewTests {
    @Test func nativeVideoHasAVisibleViewportAndAPlayableItem() async throws {
        let temporary = TemporaryPath()
        try await MediaFixtures.make(in: temporary.url)
        let path = temporary.url.appending(path: "sample.mov").path
        let file = FilePreview(path: path, status: .binary, text: nil, message: nil, version: nil)
        let hosting = NSHostingView(
            rootView: MediaPreview(file: file, folder: temporary.path, format: .video, isVisible: true))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.contentView = hosting
        defer { window.contentView = nil }
        for _ in 0..<200 {
            hosting.layoutSubtreeIfNeeded()
            if let view = playerView(in: hosting), view.player?.currentItem?.status == .readyToPlay { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let view = try #require(playerView(in: hosting))
        #expect(
            view.frame.width > 500, "Video frame: \(view.frame), host: \(String(describing: view.superview?.bounds))")
        #expect(view.frame.height > 300)
        #expect(!view.isHiddenOrHasHiddenAncestor)
        #expect(view.player != nil)
        #expect(view.player?.currentItem?.status == .readyToPlay)
    }

    private func playerView(in view: NSView) -> AVPlayerView? {
        if let player = view as? AVPlayerView { return player }
        for child in view.subviews { if let found = playerView(in: child) { return found } }
        return nil
    }
}
