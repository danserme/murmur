import AVFoundation
import SwiftUI

struct AudioPreview: View {
    let url: URL
    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var duration: Double = 0
    @State private var current: Double = 0
    @State private var timeObserver: Any?

    var body: some View {
        HStack(spacing: 8) {
            Button {
                toggle()
            } label: {
                Label(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LTTheme.ink.opacity(0.78))
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(LTTheme.wash)
                    .overlay(Capsule().strokeBorder(LTTheme.hairline, lineWidth: 0.5))
                    .clipShape(Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .help(isPlaying ? "Pause playback" : "Play the recording")

            Text(timeLabel)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(LTTheme.muted)
        }
        .onAppear { attach() }
        .onChange(of: url) { _, _ in attach() }
        .onDisappear { detach() }
    }

    private var timeLabel: String {
        "\(format(current)) / \(format(duration))"
    }

    private func attach() {
        detach()
        let item = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: item)
        player = newPlayer
        duration = 0
        current = 0
        isPlaying = false

        Task {
            if let cmDuration = try? await item.asset.load(.duration) {
                duration = cmDuration.seconds.isFinite ? cmDuration.seconds : 0
            }
        }

        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = newPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            current = time.seconds.isFinite ? time.seconds : 0
            isPlaying = newPlayer.rate > 0
        }
    }

    private func detach() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        player?.pause()
        player = nil
        isPlaying = false
    }

    private func toggle() {
        guard let player else { return }
        if player.rate > 0 {
            player.pause()
            isPlaying = false
        } else {
            if current >= duration, duration > 0 {
                player.seek(to: .zero)
            }
            player.play()
            isPlaying = true
        }
    }

    private func format(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
