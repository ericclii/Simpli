import SwiftUI

extension AppState {

    /// The services NoScroll wraps.
    ///
    /// Each is shown as a brand-coloured tile with a simple mark (BrandMark).
    struct Service: Identifiable, Hashable {
        let id: String
        let name: String
        let home: URL
        let tint: Color
        let tintDark: Color
        /// Beta services are wrapped but not yet verified against the live site.
        let beta: Bool

        var gradient: LinearGradient {
            LinearGradient(colors: [tint, tintDark], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    static let services: [Service] = [
        Service(id: "instagram", name: "Instagram",
                home: URL(string: "https://www.instagram.com/")!,
                tint: Color(hex: 0xE1306C), tintDark: Color(hex: 0xF77737), beta: false),

        Service(id: "youtube", name: "YouTube",
                home: URL(string: "https://m.youtube.com/")!,
                tint: Color(hex: 0xE02F2F), tintDark: Color(hex: 0x9E1B1B), beta: false),

        Service(id: "x", name: "X",
                home: URL(string: "https://x.com/home")!,
                tint: Color(hex: 0x2B2B2B), tintDark: Color(hex: 0x0A0A0A), beta: true),

        Service(id: "tiktok", name: "TikTok",
                home: URL(string: "https://www.tiktok.com/following")!,
                tint: Color(hex: 0x25F4EE), tintDark: Color(hex: 0xFE2C55), beta: true),

        Service(id: "facebook", name: "Facebook",
                home: URL(string: "https://m.facebook.com/")!,
                tint: Color(hex: 0x4267B2), tintDark: Color(hex: 0x1D3557), beta: true),

        Service(id: "linkedin", name: "LinkedIn",
                home: URL(string: "https://www.linkedin.com/feed/")!,
                tint: Color(hex: 0x0A66C2), tintDark: Color(hex: 0x004182), beta: true),

        Service(id: "snapchat", name: "Snapchat",
                home: URL(string: "https://web.snapchat.com/")!,
                tint: Color(hex: 0xFFFC00), tintDark: Color(hex: 0xE0A800), beta: true),

        Service(id: "reddit", name: "Reddit",
                home: URL(string: "https://www.reddit.com/")!,
                tint: Color(hex: 0xFF4500), tintDark: Color(hex: 0xC33B00), beta: true),
    ]

    /// Sites each service may load as its top-level page. Anything else opens
    /// in Safari (see WrappedWebViewController). Kept per service so one
    /// service's window can never turn into another's, where the other's rules
    /// would not apply.
    static let serviceDomains: [String: [String]] = [
        "instagram": ["instagram.com", "cdninstagram.com", "facebook.com", "fbcdn.net", "meta.com"],
        "youtube": ["youtube.com", "youtu.be", "youtube-nocookie.com"],
        "x": ["x.com", "twitter.com", "t.co", "twimg.com"],
        "tiktok": ["tiktok.com", "tiktokv.com", "tiktokcdn.com"],
        "facebook": ["facebook.com", "fb.com", "fbcdn.net", "meta.com", "messenger.com"],
        "linkedin": ["linkedin.com", "licdn.com", "lnkd.in"],
        "snapchat": ["snapchat.com", "snap.com"],
        "reddit": ["reddit.com", "redd.it", "redditmedia.com", "redditstatic.com"],
    ]

    static func service(_ id: String) -> Service? {
        services.first { $0.id == id }
    }
}
