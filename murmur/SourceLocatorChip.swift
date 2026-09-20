import AppKit
import Observation
import SwiftUI

@Observable
final class SourceLocatorModel {
    var failed = false
    var action: () -> Void = {}
    var generation = 0

    func update(failed: Bool, action: @escaping () -> Void, newlyShown: Bool) {
        self.failed = failed
        self.action = action
        if newlyShown {
            generation += 1
        }
    }
}

struct SourceLocatorChip: View {
    var model: SourceLocatorModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    @State private var hovering = false
    @State private var sheen: CGFloat = -1.1
    @State private var angle: Double = 0
    @State private var glow: Double = 0.16

    var body: some View {
        Button(action: model.action) {
            HStack(spacing: 7) {
                Image(systemName: model.failed ? "questionmark.circle.fill" : "text.quote")
                    .font(.system(size: 12, weight: .semibold))
                Text(model.failed ? "Not in transcript" : "Show in transcript")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(LTTheme.ink)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background {
                SourceLocatorFill(failed: model.failed)
            }
            .overlay {
                sheenOverlay
            }
            .overlay {
                Capsule()
                    .strokeBorder(borderGradient, lineWidth: 1)
            }
            .clipShape(Capsule())
            .shadow(color: glowColor.opacity(glow), radius: 16, y: 0)
            .shadow(color: Color.black.opacity(0.14), radius: 10, y: 4)
        }
        .buttonStyle(SourceLocatorButtonStyle())
        .pointerStyle(.link)
        .scaleEffect(shown ? (hovering ? 1.03 : 1) : 0.94)
        .opacity(shown ? 1 : 0)
        .offset(y: shown ? 0 : 5)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.16)) {
                self.hovering = hovering
            }
        }
        .onAppear { play(model.generation) }
        .onChange(of: model.generation) { _, generation in
            play(generation)
        }
        .help("Highlight the original transcript this selection is based on")
    }

    private var glowColor: Color {
        model.failed ? LTTheme.record : LTTheme.accent
    }

    private var borderGradient: AngularGradient {
        let tint = model.failed ? LTTheme.record : LTTheme.accent
        let deep = model.failed ? LTTheme.record : LTTheme.brand
        return AngularGradient(
            colors: [
                tint.opacity(0.95),
                deep.opacity(0.25),
                tint.opacity(0.18),
                deep.opacity(0.55),
                tint.opacity(0.95)
            ],
            center: .center,
            angle: .degrees(angle)
        )
    }

    private var sheenOverlay: some View {
        Capsule()
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0),
                        Color.white.opacity(hovering ? 0.38 : 0.22),
                        Color.white.opacity(0)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .scaleEffect(x: 0.42, y: 1.8)
            .offset(x: sheen * 110)
            .opacity(reduceMotion ? 0 : 1)
            .allowsHitTesting(false)
    }

    private func play(_ generation: Int) {
        shown = false
        sheen = -1.1
        angle = 0
        glow = 0.16

        if reduceMotion {
            shown = true
            return
        }

        withAnimation(.spring(duration: 0.28, bounce: 0.16)) {
            shown = true
        }
        withAnimation(.linear(duration: 2.8).repeatForever(autoreverses: false)) {
            sheen = 1.1
        }
        withAnimation(.linear(duration: 10).repeatForever(autoreverses: false)) {
            angle = 360
        }
        withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
            glow = 0.28
        }
    }
}

private struct SourceLocatorButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct SourceLocatorFill: View {
    var failed: Bool

    var body: some View {
        ZStack {
            LTTheme.popover
            LinearGradient(
                colors: failed
                    ? [
                        LTTheme.record.opacity(0.20),
                        LTTheme.popover,
                        LTTheme.record.opacity(0.10)
                    ]
                    : [
                        LTTheme.accent.opacity(0.22),
                        LTTheme.popover,
                        LTTheme.brand.opacity(0.10)
                    ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

final class SourceLocatorHostView: NSHostingView<SourceLocatorChip> {
    required init(rootView: SourceLocatorChip) {
        super.init(rootView: rootView)
        wantsLayer = true
        layer?.masksToBounds = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { false }

    override func becomeFirstResponder() -> Bool {
        false
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.iBeam.set()
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .cursorUpdate, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
        )
    }
}
