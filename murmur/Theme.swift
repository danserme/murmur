import AppKit
import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme {
        switch self {
        case .light: .light
        case .dark: .dark
        }
    }

    static func resolved(from rawValue: String) -> AppAppearance {
        if rawValue == "dark" { return .dark }
        return .light
    }
}

enum LTTheme {
    static let brand = Color(hex: 0x1500CE)
    static let record = Color(hex: 0xD23B3B)

    static let canvas = Color(light: Color(hex: 0xF3F1EC), dark: Color(hex: 0x121211))
    static let ink = Color(light: Color(hex: 0x1C1B19), dark: Color(hex: 0xF4F2EE))
    static let muted = Color(light: Color(hex: 0x8A8680), dark: Color(hex: 0x9C9892))
    static let accent = Color(light: brand, dark: Color(hex: 0xC4BFFF))
    static let wash = Color(light: Color.white.opacity(0.72), dark: Color.white.opacity(0.06))
    static let hairline = Color(light: Color.black.opacity(0.06), dark: Color.white.opacity(0.08))
    static let popover = Color(light: Color.white, dark: Color(hex: 0x1F1F1C))
    static let selectionFill = Color(light: Color(hex: 0xB7B0FF, alpha: 0.46), dark: Color(hex: 0x8F86FF, alpha: 0.40))
    static let sourceFill = Color(light: Color(hex: 0xC4BFFF, alpha: 0.34), dark: Color(hex: 0xC4BFFF, alpha: 0.26))

    static let spaceXS: CGFloat = 8
    static let spaceSM: CGFloat = 12
    static let spaceMD: CGFloat = 16
    static let spaceLG: CGFloat = 28
    static let radius: CGFloat = 22
    static let controlHeight: CGFloat = 30

    static let labelFont: Font = .system(size: 12, weight: .medium)
    static let bodyFont: Font = .system(size: 16, weight: .regular)
    static let statusFont: Font = .system(size: 13, weight: .regular)
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }

    init(light: Color, dark: Color) {
        self.init(
            nsColor: NSColor(name: nil) { appearance in
                let useDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return NSColor(useDark ? dark : light)
            }
        )
    }
}

struct AppearanceToggle: View {
    @AppStorage("appAppearance") private var appearanceRaw = AppAppearance.light.rawValue

    private var appearance: AppAppearance {
        AppAppearance.resolved(from: appearanceRaw)
    }

    var body: some View {
        HStack(spacing: 0) {
            icon("sun.max.fill", option: .light)
            icon("moon.fill", option: .dark)
        }
        .padding(2)
        .background(LTTheme.wash)
        .overlay(
            Capsule()
                .strokeBorder(LTTheme.hairline, lineWidth: 0.5)
        )
        .clipShape(Capsule())
        .help("Current theme: \(appearance.title)")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Theme")
        .accessibilityValue(appearance.title)
    }

    private func icon(_ systemName: String, option: AppAppearance) -> some View {
        let selected = appearance == option
        return Button {
            appearanceRaw = option.rawValue
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(selected ? LTTheme.ink : LTTheme.muted)
                .frame(width: 28, height: 26)
                .background(selected ? LTTheme.ink.opacity(0.08) : Color.clear)
                .clipShape(Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .accessibilityLabel(option.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// Round, icon-only control for secondary actions. Keep a text `Label` so VoiceOver still reads its name.
struct LTIconButtonStyle: ButtonStyle {
    var size: CGFloat = LTTheme.controlHeight
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(isEnabled ? LTTheme.ink.opacity(0.78) : LTTheme.muted.opacity(0.5))
            .frame(width: size, height: size)
            .background(isEnabled ? LTTheme.wash : LTTheme.wash.opacity(0.5))
            .overlay(Circle().strokeBorder(LTTheme.hairline, lineWidth: 0.5))
            .clipShape(Circle())
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .pointerStyle(isEnabled ? .link : .default)
    }
}
