import AVFoundation
import Foundation
import Observation

/// Playback is presentation state; retain one player and observe its real clock and rate.
@Observable
final class VideoPlaybackModel {
    let player: AVPlayer
    let duration: Double
    private(set) var position = 0.0
    private(set) var isPlaying = false
    private var rateObservation: NSKeyValueObservation?
    private var timeObservation: Any?

    init(player: AVPlayer, duration: Double) {
        self.player = player
        self.duration = duration.isFinite ? max(0, duration) : 0
        rateObservation = player.observe(\.rate, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                isPlaying = self.player.rate > 0
            }
        }
        timeObservation = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let seconds = self.player.currentTime().seconds
                if seconds.isFinite { position = max(0, min(seconds, duration)) }
            }
        }
    }

    func togglePlayback() {
        if player.rate > 0 {
            player.pause()
        } else {
            if duration > 0, position >= duration - 0.05 { seek(to: 0) }
            player.play()
        }
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite, duration > 0 else { return }
        let value = max(0, min(seconds, duration))
        player.seek(to: CMTime(seconds: value, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    static func timeLabel(_ seconds: Double) -> String {
        let value = seconds.isFinite && seconds >= 0 && seconds < Double(Int.max) ? max(0, Int(seconds)) : 0
        return String(format: "%d:%02d", value / 60, value % 60)
    }

    isolated deinit {
        player.pause()
        rateObservation?.invalidate()
        if let timeObservation { player.removeTimeObserver(timeObservation) }
    }
}
