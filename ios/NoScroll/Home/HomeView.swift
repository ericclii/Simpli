import SwiftUI

/// The home screen: one service at a time in a horizontal carousel, with today's
/// usage above it and a small button for that service's blocking settings
/// below, plus a light/dark toggle and a coffee link along the top. Nothing
/// else: no title, no shortcuts, no banners.
///
/// One service per page rather than a grid, because the grid invites browsing —
/// and an app about not browsing should open onto a decision, not a menu.
struct HomeView: View {
    @EnvironmentObject private var state: AppState

    @State private var selection: String = AppState.services[0].id
    @State private var openService: AppState.Service?
    @State private var showSettingsFor: AppState.Service?
    @State private var showAccountsFor: AppState.Service?
    @AppStorage(Appearance.storageKey) private var appearance = Appearance.initial
    @Environment(\.colorScheme) private var colorScheme
    /// Where the light/dark toggle is on screen: the theme change spreads
    /// out from its centre.
    @State private var toggleFrame = CGRect.zero

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            if !state.visibleServices.isEmpty { usage }
            carousel

            if let service = AppState.service(selection), !state.hiddenServices.contains(service.id) {
                blockingSettingsButton(service)
                    .padding(.top, 28)
            }

            Spacer(minLength: 0)
        }
        // Over the content, so the centred carousel doesn't move.
        .overlay(alignment: .top) {
            topButtons
                .padding(.horizontal, 32)
                .padding(.top, 8)
        }
        .background(Theme.paper.ignoresSafeArea())
        .fullScreenCover(item: $openService) { WebScreen(service: $0) }
        .sheet(item: $showSettingsFor) { ServiceSettingsView(service: $0) }
        .sheet(item: $showAccountsFor) { service in
            AccountsSheet(service: service) { openService = service }
        }
        // A widget tap lands here: select that service and open it straight
        // away, so the shortcut is one tap rather than two.
        .onChange(of: state.pendingService) { _, id in
            guard let id, let service = AppState.service(id) else { return }
            selection = id
            openService = service
            state.pendingService = nil
        }
        .onAppear(perform: keepSelectionVisible)
        .onChange(of: state.hiddenServices) { _, _ in keepSelectionVisible() }
        // A tick per app swiped to. Skipped when the old app was just hidden
        // and the carousel is only being moved off it.
        .onChange(of: selection) { old, _ in
            if state.visibleServices.contains(where: { $0.id == old }) { Haptics.tap() }
        }
    }

    // MARK: - Pieces

    /// Light/dark on the left, the coffee link on the right, each the size of
    /// the web screens' floating ☰ button.
    private var topButtons: some View {
        HStack {
            Button {
                Haptics.tap()
                let next: Appearance = colorScheme == .dark ? .light : .dark
                ThemeTransition.run(from: CGPoint(x: toggleFrame.midX, y: toggleFrame.midY)) {
                    appearance = next
                }
            } label: {
                GlassCircleIcon(systemName: colorScheme == .dark ? "moon.fill" : "sun.max.fill")
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { toggleFrame = $0 }
            .accessibilityLabel(colorScheme == .dark ? "Dark mode. Switch to light" : "Light mode. Switch to dark")

            Spacer()

            Link(destination: URL(string: "https://buymeacoffee.com/ericli")!) {
                GlassCircleIcon(systemName: "cup.and.saucer.fill")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Buy me a coffee")
        }
    }

    private var usage: some View {
        VStack(spacing: 2) {
            Text("\(AppState.service(selection)?.name.uppercased() ?? "") TODAY")
                .font(Theme.eyebrowFont)
                .tracking(Theme.eyebrowTracking)
                .foregroundStyle(Theme.inkSoft)
            // Same face as the eyebrow above it, just larger.
            Text(state.usageToday(for: selection))
                .font(Theme.hero)
                .foregroundStyle(Theme.ink)
                .contentTransition(.numericText())
        }
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private var carousel: some View {
        if state.visibleServices.isEmpty {
            ContentUnavailableView(
                "No apps on your home screen",
                systemImage: "square.dashed",
                description: Text("Turn on \u{201C}Show on home screen\u{201D} for an app in Settings.")
            )
            .frame(height: 300)
        } else {
            TabView(selection: $selection) {
                ForEach(state.visibleServices) { service in
                    ServiceTile(
                        service: service,
                        accountLabel: state.label(for: state.activeAccount(for: service.id)),
                        onOpen: { Haptics.tap(); openService = service },
                        onSwitchAccounts: { Haptics.tap(); showAccountsFor = service }
                    )
                    // The pager clips to its frame, so the icon's glow needs
                    // room inside it or it is cut off at the bottom.
                    .padding(.bottom, 44)
                    .tag(service.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: state.visibleServices.count > 1 ? .always : .never))
            .indexViewStyle(.page(backgroundDisplayMode: .never))
            .frame(height: 300)
            .animation(.snappy, value: selection)
        }
    }

    /// Keeps the carousel on a service that is actually shown.
    private func keepSelectionVisible() {
        let visible = state.visibleServices
        if !visible.contains(where: { $0.id == selection }), let first = visible.first {
            selection = first.id
        }
    }

    /// A small Liquid Glass capsule for the selected service's blocking
    /// settings; it follows the carousel.
    private func blockingSettingsButton(_ service: AppState.Service) -> some View {
        Button {
            Haptics.tap()
            showSettingsFor = service
        } label: {
            Label("\(service.name) Blocking Settings", systemImage: "slider.horizontal.3")
                .font(Theme.secondary.weight(.semibold))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 6)
                .contentTransition(.opacity)
        }
        .modifier(GlassCapsuleButton())
        .animation(.snappy, value: service.id)
    }
}

/// One service in the carousel.
struct ServiceTile: View {
    let service: AppState.Service
    let accountLabel: String
    let onOpen: () -> Void
    let onSwitchAccounts: () -> Void

    /// Every tile has the same shape: the account row sits above the icon,
    /// and tiles without one keep an invisible row of the same height, so all
    /// app icons sit at exactly the same place in the carousel.
    var body: some View {
        VStack(spacing: 16) {
            accountRow
            Button(action: onOpen) {
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .fill(service.gradient)
                    .frame(width: 152, height: 152)
                    .overlay { BrandMark(service: service.id, size: 62) }
                    .overlay(alignment: .bottom) {
                        if service.beta {
                            Text("BETA")
                                .font(Theme.eyebrow(11))
                                .tracking(1)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Color.black.opacity(0.75), in: Capsule())
                                .offset(y: 10)
                        }
                    }
                    .shadow(color: service.tintDark.opacity(0.35), radius: 22, y: 12)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var accountRow: some View {
        let row = HStack(spacing: 6) {
            Image(systemName: "person.2.circle")
            Text(accountLabel)
            Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
        }
        .font(Theme.secondary)
        .foregroundStyle(Theme.inkSoft)

        if service.id == "instagram" {
            Button(action: onSwitchAccounts) { row.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityLabel("Switch accounts. Current: \(accountLabel)")
        } else {
            row.hidden().accessibilityHidden(true)
        }
    }
}

/// Light tap feedback for the app's own controls: the home screen and the
/// floating menu. Deliberately never fired by the web pages themselves, which
/// should feel like the sites.
enum Haptics {
    @MainActor static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

/// Switch between, add, and remove a service's accounts. Each account has its
/// own sign-in; choosing one opens the service as that account.
struct AccountsSheet: View {
    let service: AppState.Service
    let onOpen: () -> Void

    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var pendingRemoval: WebSession?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(state.accounts(for: service.id)) { account in
                        Button {
                            Haptics.tap()
                            state.selectAccount(account)
                            open()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "person.crop.circle.fill")
                                    .font(.system(size: 26))
                                    .foregroundStyle(Theme.inkSoft)
                                Text(state.label(for: account))
                                    .foregroundStyle(Theme.ink)
                                Spacer()
                                if account.id == state.activeAccount(for: service.id).id {
                                    Image(systemName: "checkmark")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(Theme.switchOn)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            // Red explicitly: the app-wide ink tint would otherwise
                            // colour it, which is near-white in dark mode.
                            Button("Remove", role: .destructive) { pendingRemoval = account }
                                .tint(.red)
                        }
                    }
                }
                .listRowBackground(Theme.card)

                Section {
                    Button {
                        Haptics.tap()
                        state.addAccount(for: service.id)
                        open()
                    } label: {
                        Label("Add account", systemImage: "plus.circle.fill")
                    }
                } footer: {
                    Text("Each account keeps its own sign-in. Swipe left to remove one; that signs it out on this device.")
                        .footnoteStyle()
                }
                .listRowBackground(Theme.card)
            }
            .themedList()
            .navigationTitle("\(service.name) accounts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog(
                pendingRemoval.map { "Remove \(state.label(for: $0))?" } ?? "",
                isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                titleVisibility: .visible
            ) {
                Button("Sign out and remove", role: .destructive) {
                    guard let account = pendingRemoval else { return }
                    Task { await state.removeAccount(account) }
                }
            } message: {
                Text("Its sign-in and data are deleted from this device.")
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// Opens the service once the sheet is gone, so the two presentations
    /// don't collide.
    private func open() {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onOpen() }
    }
}

/// Liquid Glass button style on iOS 26+, a bordered capsule before that.
private struct GlassCapsuleButton: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
        } else {
            content
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
        }
    }
}

/// An icon in a 52-point glass circle, matching the web screens' floating
/// ☰ button: Liquid Glass on iOS 26+, a material circle before that.
private struct GlassCircleIcon: View {
    let systemName: String

    var body: some View {
        let icon = Image(systemName: systemName)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(Theme.ink)
            .frame(width: 52, height: 52)
            .contentShape(Circle())
        if #available(iOS 26.0, *) {
            icon.glassEffect(.regular.interactive(), in: Circle())
        } else {
            icon
                .background(.regularMaterial, in: Circle())
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        }
    }
}

/// Changes the app's light/dark theme with the new one spreading out in a
/// circle from a point (the toggle), rather than switching in one frame.
///
/// A snapshot of the window as it is now is laid over everything, the theme
/// is switched underneath it, and a hole in the snapshot grows from the point
/// until it uncovers the whole screen. The status bar isn't in the snapshot,
/// so it changes at the start. With Reduce Motion on, the themes crossfade.
@MainActor
enum ThemeTransition {
    static func run(from point: CGPoint, change: @escaping () -> Void) {
        guard let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows)
                .first(where: \.isKeyWindow),
              !UIAccessibility.isReduceMotionEnabled,
              let snapshot = window.snapshotView(afterScreenUpdates: false)
        else {
            crossfade(change)
            return
        }

        // On top of everything; it also takes any taps until it's gone.
        snapshot.frame = window.bounds
        window.addSubview(snapshot)

        // Switch underneath, unanimated, so the hole shows the finished theme.
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { change() }

        let bounds = window.bounds
        let corners = [CGPoint(x: bounds.minX, y: bounds.minY), CGPoint(x: bounds.maxX, y: bounds.minY),
                       CGPoint(x: bounds.minX, y: bounds.maxY), CGPoint(x: bounds.maxX, y: bounds.maxY)]
        let radius = corners.map { hypot($0.x - point.x, $0.y - point.y) }.max() ?? 0

        /// The whole snapshot minus a circle: even-odd fill leaves the circle
        /// as a hole.
        func shown(minus circleRadius: CGFloat) -> CGPath {
            let path = UIBezierPath(rect: bounds)
            path.append(UIBezierPath(arcCenter: point, radius: circleRadius,
                                     startAngle: 0, endAngle: 2 * .pi, clockwise: true))
            return path.cgPath
        }

        let mask = CAShapeLayer()
        mask.fillRule = .evenOdd
        mask.path = shown(minus: radius)
        snapshot.layer.mask = mask

        let grow = CABasicAnimation(keyPath: "path")
        grow.fromValue = shown(minus: 0)
        grow.toValue = mask.path
        grow.duration = 0.45
        grow.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { snapshot.removeFromSuperview() }
        mask.add(grow, forKey: "grow")
        CATransaction.commit()
    }

    private static func crossfade(_ change: @escaping () -> Void) {
        guard let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows)
                .first(where: \.isKeyWindow) else {
            change()
            return
        }
        UIView.transition(with: window, duration: 0.25, options: .transitionCrossDissolve) {
            change()
        }
    }
}
