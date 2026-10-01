import SwiftUI

/// The visual language.
///
/// Warm paper rather than the usual wellness-app white: the whole point is that
/// this should not feel like another productivity dashboard scoring you.
enum Theme {

    // MARK: - Colour

    /// Neutral greys by day, matching iOS's own grouped backgrounds (and so
    /// the Settings tab); warm charcoal by night.
    static let paper = Color(light: 0xF2F2F7, dark: 0x171613)
    /// Rows and cards sitting on `paper`.
    static let card = Color(light: 0xFFFFFF, dark: 0x24221F)
    static let ink = Color(light: 0x141414, dark: 0xF3EEE4)
    /// Secondary text. By day, darker than iOS's usual secondary grey, which
    /// reads at under 3:1 on `paper`; this passes 4.5:1 while staying grey.
    static let inkSoft = Color(light: 0x6C6C70, dark: 0x9C978A)

    /// Chart colours, one per service in a fixed order (the order of
    /// AppState.services), so an app keeps its colour whatever else is shown.
    /// A validated categorical palette, stepped separately for light and dark;
    /// brand colours were rejected: Instagram's pink and YouTube's red sit
    /// ΔE 7.5 apart, too close to tell apart even with full colour vision.
    static let series: [Color] = [
        Color(light: 0x2A78D6, dark: 0x3987E5), // blue
        Color(light: 0xEB6834, dark: 0xD95926), // orange
        Color(light: 0x1BAF7A, dark: 0x199E70), // aqua
        Color(light: 0xEDA100, dark: 0xC98500), // yellow
        Color(light: 0xE87BA4, dark: 0xD55181), // magenta
        Color(light: 0x008300, dark: 0x008300), // green
        Color(light: 0x4A3AA7, dark: 0x9085E9), // violet
        Color(light: 0xE34948, dark: 0xE66767), // red
    ]

    /// On-colour for switches. The app tint is `ink`, which is near-white in
    /// dark mode and would turn an enabled switch into a solid white oval under
    /// its white knob; system green reads clearly in both appearances.
    static let switchOn = Color.green

    // MARK: - Type

    /// Display face. The system rounded weightings carry the same friendly-but-
    /// blunt tone as the reference without shipping a licensed font.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .black) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    static func body(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    /// Small letterspaced caps used for section eyebrows ("INSTAGRAM TODAY").
    static func eyebrow(_ size: CGFloat = 13) -> Font {
        .system(size: size, weight: .semibold, design: .rounded)
    }
    static let eyebrowTracking: CGFloat = 2.2

    // The type scale. Every screen uses only these, so sizes match app-wide.
    // Rows, secondary text and captions follow the user's Dynamic Type size.

    /// Letterspaced caps labels ("INSTAGRAM TODAY", section headers).
    static let eyebrowFont = eyebrow(13)
    /// Big time figures (home "today", Screen Time average).
    static let hero = Font.system(size: 44, weight: .semibold, design: .rounded)
    /// List rows: 17 pt, the same as the Settings switches.
    static let row = Font.system(.body, design: .rounded)
    /// Dates, the account switcher, buttons: 15 pt.
    static let secondary = Font.system(.subheadline, design: .rounded)
    /// Footnotes under sections: 13 pt.
    static let caption = Font.system(.footnote, design: .rounded)
    /// Chart axis labels.
    static let axis = Font.system(size: 12, weight: .medium, design: .rounded)

    /// Navigation titles, drawn by UIKit, so set through its appearance API.
    static func styleNavigationBars() {
        let ink = UIColor(light: 0x141414, dark: 0xF3EEE4)
        func rounded(_ size: CGFloat, _ weight: UIFont.Weight) -> UIFont {
            let base = UIFont.systemFont(ofSize: size, weight: weight)
            guard let desc = base.fontDescriptor.withDesign(.rounded) else { return base }
            return UIFont(descriptor: desc, size: size)
        }
        let appearance = UINavigationBar.appearance()
        appearance.largeTitleTextAttributes = [.font: rounded(34, .bold), .foregroundColor: ink]
        appearance.titleTextAttributes = [.font: rounded(17, .semibold), .foregroundColor: ink]
    }
}

extension Color {
    /// A colour that switches with the system light/dark appearance.
    init(light: UInt32, dark: UInt32) {
        self.init(UIColor(light: light, dark: dark))
    }

    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

extension UIColor {
    /// A UIKit colour that switches with light/dark appearance.
    convenience init(light: UInt32, dark: UInt32) {
        self.init { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
    }
}

// MARK: - Shared list styling

/// A section header in the home screen's eyebrow style ("INSTAGRAM TODAY").
struct EyebrowHeader<Leading: View>: View {
    let title: String
    @ViewBuilder var leading: Leading

    var body: some View {
        HStack(spacing: 8) {
            leading
            Text(title.uppercased())
                .font(Theme.eyebrowFont)
                .tracking(Theme.eyebrowTracking)
                .foregroundStyle(Theme.inkSoft)
        }
        .textCase(nil)
    }
}

extension EyebrowHeader where Leading == EmptyView {
    init(_ title: String) {
        self.init(title: title) { EmptyView() }
    }
}

extension View {
    /// Lists sit on the home screen's background with card-coloured rows, so
    /// every screen shares one palette.
    func themedList() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(Theme.paper.ignoresSafeArea())
    }

    /// Footer and note text under list sections.
    func footnoteStyle() -> some View {
        self.font(Theme.caption).foregroundStyle(Theme.inkSoft)
    }
}
