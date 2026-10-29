import AppKit
import Charts
import SwiftUI

/// Every color the app draws with. Each one has a light and a dark value and
/// switches with the Mac's appearance on its own, so views never check the
/// color scheme themselves.
enum Theme {
    /// Window background.
    static let background = Color(nsColor: NSColors.background)
    /// Panels, cards and rows that sit on the background.
    static let panel = color(light: 0xFFFFFF, dark: 0x302C25)
    /// Panel and row outlines.
    static let border = color(light: 0xE2D9C8, dark: 0x5A5244)
    /// Unselected outlines and chart baselines.
    static let line = Color(nsColor: NSColors.line)
    static let text = color(light: 0x1F1B14, dark: 0xFFFAF0)
    static let mutedText = Color(nsColor: NSColors.mutedText)

    /// Selection, links, switches and the main buttons. AppKit controls
    /// such as switches and default buttons take the app accent color
    /// instead, so Assets.xcassets/AccentColor holds the same two values.
    static let cyan = Color(nsColor: NSColors.accent)
    /// Costs and success.
    static let green = color(light: 0x22A05A, dark: 0x7ED69A)
    /// Setting values.
    static let violet = color(light: 0x8A5CD0, dark: 0xC9A8EF)
    /// Transcribing, queued work and warnings.
    static let amber = color(light: 0xD98A0B, dark: 0xF5B947)
    /// Recording, failures and errors.
    static let orangeRed = color(light: 0xE8551F, dark: 0xFF7A4D)

    static let accent = cyan

    static let cornerRadius: CGFloat = 8
    static let rowCornerRadius: CGFloat = 6

    /// The same colors for AppKit views and windows.
    enum NSColors {
        static let background = nsColor(light: 0xFBF8F2, dark: 0x26231D)
        static let accent = nsColor(light: 0x0E9AA0, dark: 0x5FD3D6)
        static let line = nsColor(light: 0xD6CBB6, dark: 0x6A604F)
        static let mutedText = nsColor(light: 0x6B6254, dark: 0xCFC4B0)
    }

    private static func color(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: nsColor(light: light, dark: dark))
    }

    private static func nsColor(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255,
                           alpha: 1)
        }
    }
}

extension View {
    /// A flat section: panel fill, thin border, no shadow.
    func themePanel() -> some View {
        background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius).strokeBorder(Theme.border, lineWidth: 1))
    }

    /// A row inside a panel. A selected row is outlined in the accent color.
    func themeRow(selected: Bool = false) -> some View {
        background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.rowCornerRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.rowCornerRadius)
                .strokeBorder(selected ? Theme.accent : Theme.border, lineWidth: 1))
    }
}

/// A text button in the accent color, muted while disabled.
struct ThemeLinkButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? Theme.accent : Theme.mutedText)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == ThemeLinkButtonStyle {
    static var themeLink: ThemeLinkButtonStyle { ThemeLinkButtonStyle() }
}

/// GroupBox drawn as a flat panel with its title above the content.
struct ThemeGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            configuration.label
                .font(.headline)
                .foregroundStyle(Theme.text)
            configuration.content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themePanel()
    }
}

extension Theme {
    /// The color at 30% over a panel, as one opaque color. Charts cannot
    /// stroke a bar, so a themed bar is a solid bar in the color with this
    /// fill drawn over it, inset by the outline width.
    static func barFill(_ color: Color) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            var fill = NSColor.clear
            appearance.performAsCurrentDrawingAppearance {
                let panel = NSColor(Theme.panel).usingColorSpace(.sRGB) ?? .white
                let tint = NSColor(color).usingColorSpace(.sRGB) ?? .gray
                fill = panel.blended(withFraction: 0.3, of: tint) ?? panel
            }
            return fill
        })
    }
}

extension ChartContent {
    /// The fill mark of a themed bar. Put it after a solid mark with the same
    /// values, both unstacked, so the solid one shows only as the outline.
    func themeBarFill(_ color: Color) -> some ChartContent {
        foregroundStyle(Theme.barFill(color))
            .clipShape(Rectangle().inset(by: 1))
            .accessibilityHidden(true)
    }
}
