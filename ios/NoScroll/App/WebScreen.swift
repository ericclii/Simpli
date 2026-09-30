import SwiftUI
import WebKit

/// Hosts the wrapped browser full-screen, with no browser chrome: the only
/// control is a small floating button, so the service feels like an app rather
/// than a web page inside one.
struct WebScreen: View {
    let service: AppState.Service

    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var handle = WebControllerHandle()
    /// When the current stretch of use began; nil while not counting.
    @State private var usageStart: Date?

    var body: some View {
        container
            // The page runs behind the home indicator, but not the keyboard:
            // SwiftUI shrinks the web view to end above it, so a site's message
            // bar (Instagram DMs) sits right above the keyboard. Left to WebKit
            // alone, the DM bar stayed hidden behind the keyboard.
            .ignoresSafeArea(.container, edges: .bottom)
            .modifier(UnderStatusBar())
            .background(Color(.systemBackground).ignoresSafeArea())
            .overlay {
                FloatingMenuButton(
                    onHome: { dismiss() },
                    onRefresh: { handle.controller?.reload() },
                    pictureInPictureState: { await handle.controller?.pictureInPictureState() ?? .unavailable },
                    onPictureInPicture: { handle.controller?.togglePictureInPicture() }
                )
            }
            // Usage: counted while this screen is up and the app is active.
            // Saved every 30 s too, so a force-quit loses at most that much.
            .onAppear { if scenePhase == .active { usageStart = Date() } }
            .onDisappear(perform: recordUsage)
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { usageStart = usageStart ?? Date() } else { recordUsage() }
            }
            .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
                guard usageStart != nil else { return }
                recordUsage()
                usageStart = Date()
            }
    }

    private func recordUsage() {
        guard let start = usageStart else { return }
        usageStart = nil
        state.addUsage(Date().timeIntervalSince(start), for: service.id)
    }

    @ViewBuilder
    private var container: some View {
        if let raw = state.rawBundles[service.id] {
            WebViewContainer(
                service: service,
                session: state.activeAccount(for: service.id),
                engineSource: state.engineSource,
                bundleRaw: raw,
                settings: state.settings,
                handle: handle,
                onUsername: { [state] name, id in state.setUsername(name, for: id) }
            )
        } else {
            ContentUnavailableView(
                "Rules unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text("Simpli refuses to open \(service.name) without a verified rule bundle.")
            )
        }
    }
}

/// On iOS 26+, lets the page run up under the status bar / Dynamic Island.
/// WrappedWebViewController then marks that strip as obscured, so WebKit keeps
/// the sites' pinned headers out of it and content scrolls up into it behind
/// the system's soft edge. Top container region only; before iOS 26 the page
/// stays below the status bar as before.
private struct UnderStatusBar: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.ignoresSafeArea(.container, edges: .top)
        } else {
            content
        }
    }
}

/// Lets SwiftUI controls reach the UIKit controller that owns the WKWebView.
@MainActor
final class WebControllerHandle: ObservableObject {
    weak var controller: WrappedWebViewController?
}

/// A draggable glass button that snaps to the nearest side edge. Tapping it
/// stretches the bubble toward the middle of the screen, then tears it apart in
/// the middle: the far half becomes a pill holding Home (nearest), Refresh and,
/// while a video plays or is in picture in picture, a Picture in Picture
/// toggle, and the near half shrinks back into
/// the ☰ circle, which stays an easy target for closing. The position is
/// remembered across launches.
struct FloatingMenuButton: View {
    let onHome: () -> Void
    let onRefresh: () -> Void
    /// Asked each time the menu opens: whether to show the Picture in Picture
    /// item, and whether it starts or ends it.
    let pictureInPictureState: () async -> WrappedWebViewController.PictureInPictureState
    let onPictureInPicture: () -> Void

    @AppStorage("noscroll.floatingButton.onLeft") private var onLeft = false
    @AppStorage("noscroll.floatingButton.y") private var yFraction = 0.72
    @State private var dragOffset: CGSize = .zero
    @State private var phase = Phase.closed
    /// Icon visibility, animated separately from the glass so the two icons
    /// can fade in and out one after the other.
    @State private var homeShown = false
    @State private var refreshShown = false
    @State private var pictureInPictureShown = false
    /// The Picture in Picture item for this opening of the menu.
    @State private var pictureInPicture = WrappedWebViewController.PictureInPictureState.unavailable
    private var offersPictureInPicture: Bool { pictureInPicture != .unavailable }
    @State private var keyboardUp = false
    @Namespace private var glassNamespace

    /// closed: one circle (the pill hides exactly underneath it).
    /// stretched: both shapes span the full width, reading as one capsule.
    /// open: the capsule has split into the pill and the circle.
    private enum Phase { case closed, stretched, open }

    /// Diameter of the ☰ circle, height of the pill, and width of each pill
    /// button, so every target in the menu is the same size.
    private let size: CGFloat = 52
    private let margin: CGFloat = 10
    /// Space between the ☰ circle and the pill once they have separated.
    private let gap: CGFloat = 12
    /// Glass shapes closer than this melt together; kept under the gap so the
    /// split completes with the two resting apart.
    private let fuseDistance: CGFloat = 10
    /// Each half of the 0.2 s open; no overshoot.
    private let stepDuration: TimeInterval = 0.1
    private var openStep: Animation { .smooth(duration: stepDuration) }
    /// The opening curve played backwards in time, so closing is a true mirror.
    /// Replaying the spring forward would start fast and fuse the glass almost
    /// instantly; reversed, it starts slow, so the merge shows the same liquid
    /// neck the split does.
    private var closeStep: Animation { Animation(ReversedSmoothStep(duration: stepDuration)) }
    private let iconSize: CGFloat = 20

    private var pillWidth: CGFloat { CGFloat(offersPictureInPicture ? 3 : 2) * size }
    private var totalWidth: CGFloat { size + gap + pillWidth }
    private var menuOpen: Bool { phase != .closed }

    var body: some View {
        GeometryReader { geo in
            let bounds = geo.size
            let anchor = anchorPoint(in: bounds)
            let origin = CGPoint(x: anchor.x + dragOffset.width, y: anchor.y + dragOffset.height)

            ZStack {
                if menuOpen {
                    // Tapping anywhere outside the menu closes it.
                    Color.black.opacity(0.001)
                        .onTapGesture { close() }
                }

                // The glass only: its frames animate through the phases while
                // the icons below stay put.
                GlassGroup(spacing: fuseDistance) {
                    ZStack {
                        glass(id: "actions", shape: Capsule(), frame: pillFrame(origin: origin))
                        glass(id: "toggle", shape: Capsule(), frame: circleFrame(origin: origin))
                    }
                    .frame(width: bounds.width, height: bounds.height)
                }
                .allowsHitTesting(false)

                actions
                    .position(x: pillCenterX(origin: origin), y: origin.y)
                    .allowsHitTesting(phase == .open)
                    .accessibilityHidden(phase != .open)

                toggle
                    .position(origin)
                    .gesture(drag(anchor: anchor, bounds: bounds))
            }
            // Hidden while typing: the page resizes above the keyboard, which
            // would otherwise move the button onto the site's message bar.
            .opacity(keyboardUp ? 0 : 1)
            .allowsHitTesting(!keyboardUp)
            .animation(.easeOut(duration: 0.15), value: keyboardUp)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            if menuOpen { phase = .closed; hideIcons() }
            keyboardUp = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardUp = false
        }
    }

    private func glass(id: String, shape: some Shape, frame: CGRect) -> some View {
        Color.clear
            .frame(width: frame.width, height: frame.height)
            .floatingGlass(in: shape, id: id, namespace: glassNamespace)
            .position(x: frame.midX, y: frame.midY)
    }

    private var toggle: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: iconSize, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: size, height: size)
            .contentShape(Circle())
            .onTapGesture {
                Haptics.tap()
                menuOpen ? close() : open()
            }
            .accessibilityLabel("Menu")
            .accessibilityAddTraits(.isButton)
    }

    /// Home sits next to the ☰, then Refresh, then Picture in Picture.
    private var actions: some View {
        HStack(spacing: 0) {
            let items = actionItems
            ForEach(onLeft ? items : items.reversed(), id: \.title) { item in
                action(item.title, systemImage: item.systemImage, shown: item.shown, run: item.run)
            }
        }
        .frame(width: pillWidth, height: size)
    }

    private var actionItems: [(title: String, systemImage: String, shown: Bool, run: () -> Void)] {
        var items: [(title: String, systemImage: String, shown: Bool, run: () -> Void)] = [
            ("Home", "house.fill", homeShown, onHome),
            ("Refresh", "arrow.clockwise", refreshShown, onRefresh),
        ]
        switch pictureInPicture {
        case .available:
            items.append(("Picture in Picture", "pip.enter", pictureInPictureShown, onPictureInPicture))
        case .active:
            items.append(("Exit Picture in Picture", "pip.exit", pictureInPictureShown, onPictureInPicture))
        case .unavailable:
            break
        }
        return items
    }

    private func action(_ title: String, systemImage: String, shown: Bool,
                        run: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            close()
            run()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(.primary)
                .opacity(shown ? 1 : 0)
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    // MARK: - Phases

    /// Icons fade in working outward from the ☰ (0.2 s open):
    ///   Home                0.03 s → 0.18 s, ease-in-out
    ///   Refresh             0.10 s → 0.20 s, ease-out
    ///   Picture in Picture  0.13 s → 0.20 s, ease-out
    /// Home fades while the glass is still stretching under it, where a short
    /// ease-out reads as a pop, so it gets a longer fade with a soft start.
    private let homeFade = (delay: 0.03, duration: 0.15)
    private let refreshFade = (delay: 0.1, duration: 0.1)
    private let pictureInPictureFade = (delay: 0.13, duration: 0.07)
    /// Length of the whole open (and close), for mirroring the fades in time.
    private var menuDuration: TimeInterval { 2 * stepDuration }

    /// Asks whether to offer Picture in Picture first; the page answers in a
    /// few milliseconds, well under a frame of the animation.
    private func open() {
        Task {
            pictureInPicture = await pictureInPictureState()
            animateOpen()
        }
    }

    private func animateOpen() {
        withAnimation(.easeOut(duration: pictureInPictureFade.duration).delay(pictureInPictureFade.delay)) {
            pictureInPictureShown = true
        }
        withAnimation(.easeInOut(duration: homeFade.duration).delay(homeFade.delay)) { homeShown = true }
        withAnimation(.easeOut(duration: refreshFade.duration).delay(refreshFade.delay)) { refreshShown = true }
        withAnimation(openStep) { phase = .stretched } completion: {
            guard phase == .stretched else { return }
            withAnimation(openStep) { phase = .open }
        }
    }

    /// The exact reverse of `open()`: the outermost icon fades out first, on
    /// the time-reversed curve, all gone before the capsule shrinks to a circle.
    private func close() {
        guard phase != .closed else { return }
        // Each fade mirrored in time: it starts where its opening fade ended,
        // counted back from the end of the close.
        let mirrored = { (fade: (delay: Double, duration: Double)) in
            max(0, self.menuDuration - fade.delay - fade.duration)
        }
        withAnimation(.easeIn(duration: pictureInPictureFade.duration).delay(mirrored(pictureInPictureFade))) {
            pictureInPictureShown = false
        }
        withAnimation(.easeIn(duration: refreshFade.duration).delay(mirrored(refreshFade))) { refreshShown = false }
        withAnimation(.easeInOut(duration: homeFade.duration).delay(mirrored(homeFade))) { homeShown = false }
        withAnimation(closeStep) { phase = .stretched } completion: {
            guard phase == .stretched else { return }
            withAnimation(closeStep) { phase = .closed }
        }
    }

    private func hideIcons() {
        homeShown = false
        refreshShown = false
        pictureInPictureShown = false
    }

    private func drag(anchor: CGPoint, bounds: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if menuOpen {
                    phase = .closed
                    hideIcons()
                }
                dragOffset = value.translation
            }
            .onEnded { value in
                let x = anchor.x + value.translation.width
                let y = anchor.y + value.translation.height
                withAnimation(.spring(duration: 0.35, bounce: 0.25)) {
                    onLeft = x < bounds.width / 2
                    yFraction = Double(clampY(y, in: bounds) / max(bounds.height, 1))
                    dragOffset = .zero
                }
            }
    }

    // MARK: - Geometry

    /// Centre of the ☰ on its edge.
    private func anchorPoint(in bounds: CGSize) -> CGPoint {
        let x = onLeft ? margin + size / 2 : bounds.width - margin - size / 2
        return CGPoint(x: x, y: clampY(CGFloat(yFraction) * bounds.height, in: bounds))
    }

    /// A span measured from the ☰'s outer edge toward the middle of the screen.
    private func span(origin: CGPoint, from start: CGFloat, width: CGFloat) -> CGRect {
        let outer = onLeft ? origin.x - size / 2 : origin.x + size / 2
        let minX = onLeft ? outer + start : outer - start - width
        return CGRect(x: minX, y: origin.y - size / 2, width: width, height: size)
    }

    private func circleFrame(origin: CGPoint) -> CGRect {
        span(origin: origin, from: 0, width: phase == .stretched ? totalWidth : size)
    }

    private func pillFrame(origin: CGPoint) -> CGRect {
        switch phase {
        case .closed: span(origin: origin, from: 0, width: size)
        case .stretched: span(origin: origin, from: 0, width: totalWidth)
        case .open: span(origin: origin, from: size + gap, width: pillWidth)
        }
    }

    private func pillCenterX(origin: CGPoint) -> CGFloat {
        let offset = size / 2 + gap + pillWidth / 2
        return onLeft ? origin.x + offset : origin.x - offset
    }

    private func clampY(_ y: CGFloat, in bounds: CGSize) -> CGFloat {
        min(max(y, margin + size / 2), bounds.height - margin - size / 2)
    }
}

/// `.smooth(duration:)` run backwards in time.
///
/// `.smooth` is a critically damped spring, whose progress from rest is
/// 1 − (1 + ωt)·e^(−ωt) with ω = 2π / duration. Reversing it means progress at
/// time t is one minus the spring's progress at (duration − t), normalised so
/// it runs exactly from 0 to 1: a slow start that ends at full speed.
private struct ReversedSmoothStep: CustomAnimation {
    let duration: TimeInterval

    func animate<V: VectorArithmetic>(value: V, time: TimeInterval,
                                      context: inout AnimationContext<V>) -> V? {
        guard time < duration else { return nil }
        let omega = 2 * Double.pi / duration
        func spring(_ t: Double) -> Double { 1 - (1 + omega * t) * exp(-omega * t) }
        let progress = (spring(duration) - spring(duration - time)) / spring(duration)
        return value.scaled(by: progress)
    }
}

// MARK: - Liquid Glass

/// Groups glass shapes so they blend and morph into each other (iOS 26+).
/// Earlier systems have no Liquid Glass, so the content renders as is.
private struct GlassGroup<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

private extension View {
    /// Liquid Glass on iOS 26+, with an identity so shapes in a GlassGroup blend
    /// while they touch. Before iOS 26, a material in the same shape.
    @ViewBuilder
    func floatingGlass(in shape: some Shape, id: String, namespace: Namespace.ID) -> some View {
        if #available(iOS 26.0, *) {
            self
                .glassEffect(.regular, in: shape)
                .glassEffectID(id, in: namespace)
        } else {
            self
                .background(.regularMaterial, in: shape)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        }
    }
}

/// Bridges the UIKit web controller into SwiftUI.
struct WebViewContainer: UIViewControllerRepresentable {
    let service: AppState.Service
    /// The account to open: its id names this web view's data store.
    let session: WebSession
    let engineSource: String
    let bundleRaw: Data
    let settings: [String: Bool]
    let handle: WebControllerHandle
    let onUsername: (String, UUID) -> Void

    func makeUIViewController(context: Context) -> WrappedWebViewController {
        let accountID = session.id
        let controller = WrappedWebViewController(
            session: session,
            startURL: service.home,
            dataStore: WKWebsiteDataStore(forIdentifier: accountID),
            engineSource: engineSource,
            bundleRaw: bundleRaw,
            settings: settings,
            onUsername: { username in
                Task { @MainActor in onUsername(username, accountID) }
            }
        )
        handle.controller = controller
        return controller
    }

    func updateUIViewController(_ controller: WrappedWebViewController, context: Context) {}
}
