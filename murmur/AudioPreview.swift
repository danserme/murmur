import AVFoundation
import SwiftUI

struct AudioPreview: View {
    let url: URL
    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var duration: Double = 0
    @State private var current: Double = 0
    @State private var timeObserver: Any?
    @State private var scrubTime: Double?

    var body: some View {
        HStack(spacing: 10) {
            Button {
                toggle()
            } label: {
                Label(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill")
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(LTIconButtonStyle())
            .help(isPlaying ? "Pause playback" : "Play the recording")

            timeText(scrubTime ?? current)

            PlaybackScrubber(
                current: scrubTime ?? current,
                duration: duration,
                onScrub: { time in
                    scrubTime = time
                    seek(to: time, precise: false)
                },
                onCommit: { time in
                    seek(to: time, precise: true)
                    current = time
                    scrubTime = nil
                }
            )
            .frame(minWidth: 90, idealWidth: 200, maxWidth: 240)

            timeText(duration)
        }
        .onAppear { attach() }
        .onChange(of: url) { _, _ in attach() }
        .onDisappear { detach() }
    }

    private func timeText(_ seconds: Double) -> some View {
        Text(format(seconds))
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .foregroundStyle(LTTheme.muted)
            .lineLimit(1)
            .fixedSize()
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

    private func seek(to seconds: Double, precise: Bool) {
        guard let player else { return }
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        let tolerance: CMTime = precise ? .zero : CMTime(seconds: 0.1, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance)
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

/// A thin seek bar: click anywhere to jump there, or drag to scrub.
private struct PlaybackScrubber: View {
    let current: Double
    let duration: Double
    let onScrub: (Double) -> Void
    let onCommit: (Double) -> Void

    @State private var isHovering = false
    @State private var isDragging = false

    private var fraction: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, current / duration))
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let isActive = isHovering || isDragging
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LTTheme.ink.opacity(0.1))
                    .frame(height: isActive ? 5 : 3)
                Capsule()
                    .fill(LTTheme.accent)
                    .frame(width: max(0, width * fraction), height: isActive ? 5 : 3)
                Circle()
                    .fill(LTTheme.accent)
                    .frame(width: 11, height: 11)
                    .shadow(color: Color.black.opacity(0.18), radius: 2, y: 1)
                    .offset(x: width * fraction - 5.5)
                    .scaleEffect(isActive ? 1 : 0.01)
                    .opacity(isActive ? 1 : 0)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        onScrub(time(at: value.location.x, width: width))
                    }
                    .onEnded { value in
                        isDragging = false
                        onCommit(time(at: value.location.x, width: width))
                    }
            )
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.15), value: isActive)
        }
        .frame(height: 28)
        .disabled(duration <= 0)
        .pointerStyle(.link)
        .help("Click or drag to move through the recording")
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(Int(current)) of \(Int(duration)) seconds")
        .accessibilityAdjustableAction { direction in
            let step = max(5, duration / 20)
            switch direction {
            case .increment: onCommit(min(duration, current + step))
            case .decrement: onCommit(max(0, current - step))
            @unknown default: break
            }
        }
    }

    private func time(at x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double(min(1, max(0, x / width))) * duration
    }
}
