import AVKit
import SwiftUI

struct VideoPreview: View {
    let playback: VideoPlaybackModel
    let isVisible: Bool
    let allowsAutomaticFocus: Bool
    @State private var seeking = false
    @State private var draft = 0.0

    private var currentTime: String { VideoPlaybackModel.timeLabel(seeking ? draft : playback.position) }

    var body: some View {
        VStack(spacing: 0) {
            VideoSurface(
                player: playback.player, isVisible: isVisible, allowsAutomaticFocus: allowsAutomaticFocus)
            HStack(spacing: 12) {
                Button(
                    playback.isPlaying ? "Pause" : "Play", systemImage: playback.isPlaying ? "pause.fill" : "play.fill"
                ) {
                    playback.togglePlayback()
                }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
                .accessibilityIdentifier("videoPlayPause")
                Slider(
                    value: Binding(
                        get: { draft },
                        set: { value in
                            draft = value
                            if !seeking { playback.seek(to: value) }
                        }), in: 0...max(1, playback.duration)
                ) { editing in
                    seeking = editing
                    if !editing { playback.seek(to: draft) }
                }
                .disabled(playback.duration <= 0)
                .accessibilityLabel("Playback position").accessibilityIdentifier("videoPosition")
                Text(
                    "\(currentTime) / \(VideoPlaybackModel.timeLabel(playback.duration))"
                )
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .accessibilityIdentifier("videoTime")
                .accessibilityValue(currentTime)
            }
            .padding(12)
        }
        .onChange(of: playback.position, initial: true) { if !seeking { draft = playback.position } }
        .onChange(of: isVisible, initial: true) { if !isVisible { playback.player.pause() } }
        .onDisappear { playback.player.pause() }
    }
}

private struct VideoSurface: NSViewRepresentable {
    let player: AVPlayer
    let isVisible: Bool
    let allowsAutomaticFocus: Bool

    func makeNSView(context: Context) -> RetainedContentHost<AVPlayerView> {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.setAccessibilityIdentifier("videoPlayer")
        return RetainedContentHost(content: view, responder: view)
    }

    func updateNSView(_ host: RetainedContentHost<AVPlayerView>, context: Context) {
        if host.content.player !== player { host.content.player = player }
        if !isVisible { player.pause() }
        host.allowsKeyboardFocus = allowsAutomaticFocus
        host.setVisible(isVisible)
    }

    static func dismantleNSView(_ host: RetainedContentHost<AVPlayerView>, coordinator: Void) {
        host.content.player?.pause()
        host.content.player = nil
        host.setVisible(false)
    }
}
