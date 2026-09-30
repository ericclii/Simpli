import SwiftUI

@main
struct NoScrollApp: App {
    @StateObject private var state = AppState()

    init() {
        Theme.styleNavigationBars()
        // The home carousel's page dots: the default white vanishes on the
        // light background, so they take the text colours instead.
        UIPageControl.appearance().currentPageIndicatorTintColor = UIColor(light: 0x141414, dark: 0xF3EEE4)
        UIPageControl.appearance().pageIndicatorTintColor = UIColor(light: 0xC7C7CC, dark: 0x57544E)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                // Widgets deep-link straight into a service: noscroll://open/instagram
                .onOpenURL { state.handle(url: $0) }
        }
    }
}

/// Shell: three tabs — settings, home, screen time.
struct RootView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(Appearance.storageKey) private var appearance = Appearance.initial

    var body: some View {
        TabView(selection: $state.tab) {
            AllSettingsTab().tag(AppState.Tab.adjust)
                .tabItem { Image(systemName: "slider.horizontal.3") }
            HomeView().tag(AppState.Tab.home)
                .tabItem { Image(systemName: "house.fill") }
            UsageTab().tag(AppState.Tab.usage)
                .tabItem { Image(systemName: "chart.bar.xaxis") }
        }
        .tint(Theme.ink)
        .onChange(of: state.tab) { _, _ in Haptics.tap() }
        // One type family across the app: the rounded system face.
        .fontDesign(.rounded)
        // The whole window follows the choice, including sheets, the web
        // screens, and the sites themselves (they read prefers-color-scheme).
        .preferredColorScheme(appearance.colorScheme)
        // A day the app is opened has data (possibly 0m) for Screen Time.
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { state.markDayActive() }
        }
    }
}
