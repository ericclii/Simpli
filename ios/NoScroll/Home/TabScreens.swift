import Charts
import SwiftUI

/// The app's settings: every service's switches in one place, rather than
/// one sheet at a time.
struct AllSettingsTab: View {
    @EnvironmentObject private var state: AppState
    /// A beta app waiting on the warning before it is shown on the home screen.
    @State private var betaToShow: AppState.Service?

    var body: some View {
        NavigationStack {
            List {
                ForEach(AppState.services) { service in
                    Section {
                        Toggle("Show on home screen", isOn: showOnHome(service))
                            .tint(Theme.switchOn)
                        // A hidden app's blocking switches are hidden too;
                        // they keep their values for when it is shown again.
                        if !state.hiddenServices.contains(service.id) {
                            ForEach(state.surfaces(for: service.id)) { group in
                                Toggle(group.label,
                                       isOn: state.binding(service: service.id, surfaces: group.keys))
                                    .tint(Theme.switchOn)
                            }
                        }
                    } header: {
                        VStack(alignment: .leading, spacing: 18) {
                            if service.id == AppState.services.first?.id {
                                Text("Settings")
                                    .font(.system(size: 34, weight: .bold, design: .rounded))
                                    .foregroundStyle(Theme.ink)
                                    .textCase(nil)
                                    .accessibilityAddTraits(.isHeader)
                            }
                            EyebrowHeader(title: service.beta ? "\(service.name) · beta" : service.name) {
                                BrandMark(service: service.id, size: 13)
                                    .padding(4)
                                    .background(service.gradient, in: RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                    .listRowBackground(Theme.card)
                }
            }
            .themedList()
            .toolbar(.hidden, for: .navigationBar)
            .alert("Warning!", isPresented: Binding(get: { betaToShow != nil },
                                                    set: { if !$0 { betaToShow = nil } }),
                   presenting: betaToShow) { service in
                Button("Cancel", role: .cancel) {}
                Button("Proceed") {
                    withAnimation(.snappy) { state.showOnHome(service.id).wrappedValue = true }
                }
            } message: { _ in
                Text("This app is still in BETA, and is not fully supported: it may not be fully functional, and there may be visual glitches. Do you wish to proceed?")
            }
        }
    }

    /// Animated so the app's other switches unfold and fold away as it is
    /// shown or hidden. Turning on a beta app asks first; the switch stays off
    /// unless the warning is accepted.
    private func showOnHome(_ service: AppState.Service) -> Binding<Bool> {
        let shown = state.showOnHome(service.id)
        return Binding(
            get: { shown.wrappedValue },
            set: { newValue in
                if newValue, service.beta {
                    betaToShow = service
                } else {
                    withAnimation(.snappy) { shown.wrappedValue = newValue }
                }
            }
        )
    }
}

/// The app's colour scheme: dark until the home screen's toggle picks light.
/// A stored "system" (from the old appearance picker) no longer decodes, so it
/// falls back to the default and opens dark too.
enum Appearance: String {
    case light, dark

    static let storageKey = "noscroll.appearance"

    var colorScheme: ColorScheme {
        switch self {
        case .light: .light
        case .dark: .dark
        }
    }

    /// Used until a choice is stored: carries over the earlier light-mode
    /// switch if it was ever set, otherwise dark.
    static var initial: Appearance {
        guard let light = UserDefaults.standard.object(forKey: "noscroll.lightMode") as? Bool else { return .dark }
        return light ? .light : .dark
    }
}

// MARK: - Screen Time

/// Time spent in each service, as a week of bars. Opens on this week; swiping
/// the chart right shows last week. The header and legend stay in place and
/// follow the week shown. Tapping an app in the legend shows only that app.
struct UsageTab: View {
    @EnvironmentObject private var state: AppState
    @State private var weekOffset = 0
    /// Index (0 = Sunday) of the day being touched on the chart, if any.
    @State private var selectedDay: Int?
    /// The app picked in the legend; nil shows every app.
    @State private var focus: String?
    /// Re-read on appearing and every 30 s, so time recorded elsewhere (or a
    /// new day) shows without a tap.
    @State private var now = Date()

    /// Picking an app: the other apps' bars shrink to nothing while the chart
    /// rescales, all in one motion.
    private let focusAnimation = Animation.smooth(duration: 0.35)

    var body: some View {
        let week = WeekUsage(offset: weekOffset, state: state, now: now)
        // A list like Settings, so the app breakdown's rows, corners and type
        // match it exactly; the header and chart sit on clear rows.
        List {
            Section {
                header(week)
                    .listRowInsets(EdgeInsets(top: 8, leading: 4, bottom: 4, trailing: 4))
                TabView(selection: $weekOffset) {
                    ForEach([-1, 0], id: \.self) { offset in
                        // Top padding keeps the highest axis label inside the
                        // pager, which clips anything drawn above its frame.
                        WeekChart(week: WeekUsage(offset: offset, state: state, now: now),
                                  focus: focus, selectedDay: $selectedDay)
                            .padding(.top, 10)
                            .tag(offset)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: 230)
                .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 8, trailing: 4))
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            Section {
                ForEach(week.services) { service in
                    legendRow(service, week: week)
                }
            }
            .listRowBackground(Theme.card)
        }
        .themedList()
        .onAppear { now = Date() }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { now = $0 }
        .onChange(of: weekOffset) { _, _ in selectedDay = nil }
    }

    private func header(_ week: WeekUsage) -> some View {
        let focused = focus.flatMap(AppState.service)
        let label = selectedDay.map { week.days[$0].formatted(.dateTime.weekday(.wide)).uppercased() } ?? "DAILY AVERAGE"
        let value: String = {
            if let day = selectedDay {
                return week.hasData[day] ? AppState.formatDuration(week.total(day: day, focus: focus)) : "No data"
            }
            return week.dailyAverage(focus: focus).map(AppState.formatDuration) ?? "—"
        }()
        return VStack(alignment: .leading, spacing: 6) {
            Text(weekOffset == 0 ? "THIS WEEK" : "LAST WEEK")
                .font(Theme.eyebrowFont)
                .tracking(Theme.eyebrowTracking)
                .foregroundStyle(Theme.inkSoft)
            Text(week.rangeText)
                .font(Theme.secondary)
                .foregroundStyle(Theme.inkSoft)
            Spacer().frame(height: 8)
            // The app's name slides in ahead of the label rather than the
            // whole line being swapped, which cross-faded two strings of
            // different lengths over each other.
            HStack(spacing: 0) {
                if let focused {
                    Text("\(focused.name.uppercased()) · ")
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                Text(label)
            }
            .font(Theme.eyebrowFont)
            .tracking(Theme.eyebrowTracking)
            .foregroundStyle(Theme.inkSoft)
            Text(value)
                .font(Theme.hero)
                .foregroundStyle(Theme.ink)
                .contentTransition(.numericText())
        }
    }

    /// One app's total for the week. Tapping shows only that app; tapping it
    /// again shows every app.
    private func legendRow(_ service: AppState.Service, week: WeekUsage) -> some View {
        Button {
            Haptics.tap()
            withAnimation(focusAnimation) { focus = focus == service.id ? nil : service.id }
        } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(WeekUsage.color(for: service))
                    .frame(width: 12, height: 12)
                Text(service.name)
                    .foregroundStyle(Theme.ink)
                Spacer()
                Text(AppState.formatDuration(week.total(for: service)))
                    .foregroundStyle(Theme.inkSoft)
                    .monospacedDigit()
                Image(systemName: "checkmark")
                    .font(Theme.row.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .opacity(focus == service.id ? 1 : 0)
            }
            .font(Theme.row)
            .contentShape(Rectangle())
            .opacity(focus == nil || focus == service.id ? 1 : 0.4)
        }
        .buttonStyle(.plain)
    }
}

/// A snapshot of one week's usage, taken as plain values so a view holding it
/// is redrawn whenever the numbers change. Shared by the header, chart and
/// legend.
@MainActor
private struct WeekUsage: Equatable {
    let offset: Int
    let days: [Date]
    let services: [AppState.Service]
    /// seconds[day][service], in `days` × `services` order.
    let seconds: [[Int]]
    /// Whether anything was recorded that day. A day with no data (before the
    /// app was installed, or one it wasn't opened) is left out of averages; a
    /// day with data but no use counts as 0m.
    let hasData: [Bool]
    /// How many of the week's days have begun (7 for last week).
    let elapsed: Int

    init(offset: Int, state: AppState, now: Date) {
        self.offset = offset
        let days = AppState.week(offset: offset)
        self.days = days
        // Every service on the home screen, plus any hidden one used this
        // week, always in the fixed service order.
        let services = AppState.services.filter { service in
            !state.hiddenServices.contains(service.id)
                || days.contains { state.usageSeconds(on: $0, for: service.id) > 0 }
        }
        self.services = services
        self.seconds = days.map { day in services.map { state.usageSeconds(on: day, for: $0.id) } }
        self.hasData = days.map { state.hasUsageData(on: $0) }
        let today = AppState.usageDay(for: now)
        self.elapsed = days.filter { $0 <= today }.count
    }

    func seconds(day: Int, service: Int) -> Int { seconds[day][service] }

    /// A day's total, for one app or all of them.
    func total(day: Int, focus: String?) -> Int {
        services.indices.reduce(0) { sum, i in
            focus == nil || services[i].id == focus ? sum + seconds[day][i] : sum
        }
    }

    func total(for service: AppState.Service) -> Int {
        guard let i = services.firstIndex(of: service) else { return 0 }
        return seconds.reduce(0) { $0 + $1[i] }
    }

    /// Averaged over the days so far that have data; nil when none do.
    func dailyAverage(focus: String?) -> Int? {
        let counted = (0..<elapsed).filter { hasData[$0] }
        guard !counted.isEmpty else { return nil }
        return counted.reduce(0) { $0 + total(day: $1, focus: focus) } / counted.count
    }

    var rangeText: String {
        "\(days[0].formatted(.dateTime.month(.abbreviated).day())) – \(days[6].formatted(.dateTime.month(.abbreviated).day()))"
    }

    /// Round gridlines (15m, 30m, 1h or 2h apart) covering the longest day.
    func yTicks(focus: String?) -> [Double] {
        let longest = Double((0..<7).map { total(day: $0, focus: focus) }.max() ?? 0) / 60
        let step: Double = longest <= 45 ? 15 : longest <= 90 ? 30 : longest <= 240 ? 60 : 120
        let top = max(step, (longest / step).rounded(.up) * step)
        return Array(stride(from: 0, through: top, by: step))
    }

    static func color(for service: AppState.Service) -> Color {
        let index = AppState.services.firstIndex(of: service) ?? 0
        return Theme.series[index % Theme.series.count]
    }
}

/// The bars for one week. Days are seven fixed slots ("0"…"6"), so each bar
/// and its weekday letter share one centre.
private struct WeekChart: View {
    let week: WeekUsage
    let focus: String?
    @Binding var selectedDay: Int?

    private static let slots = (0..<7).map(String.init)
    private static let letters = Calendar(identifier: .gregorian).veryShortStandaloneWeekdaySymbols

    /// Every service keeps its marks while an app is picked; the others
    /// just go to zero height. Removing them instead made Charts fade them
    /// out while the stack re-laid itself, so they drifted off to the side.
    private func minutes(day: Int, service i: Int) -> Double {
        focus == nil || week.services[i].id == focus
            ? Double(week.seconds(day: day, service: i)) / 60 : 0
    }

    var body: some View {
        let ticks = week.yTicks(focus: focus)
        Chart {
            ForEach(0..<7, id: \.self) { day in
                ForEach(week.services.indices, id: \.self) { i in
                    BarMark(x: .value("Day", Self.slots[day]),
                            y: .value("Minutes", minutes(day: day, service: i)),
                            width: .ratio(0.55))
                        .foregroundStyle(by: .value("App", week.services[i].name))
                        .cornerRadius(4)
                        .opacity(selectedDay == nil || selectedDay == day ? 1 : 0.35)
                }
            }
            if let average = week.dailyAverage(focus: focus), average > 0 {
                RuleMark(y: .value("Average", Double(average) / 60))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(Theme.inkSoft)
            }
        }
        .chartForegroundStyleScale(domain: week.services.map(\.name),
                                   range: week.services.map(WeekUsage.color(for:)))
        .chartLegend(.hidden)
        .chartXScale(domain: Self.slots)
        .chartXAxis {
            AxisMarks(values: Self.slots) { value in
                AxisValueLabel(centered: true) {
                    if let slot = value.as(String.self), let i = Int(slot) {
                        Text(Self.letters[i])
                            .font(Theme.axis)
                            .foregroundStyle(Theme.inkSoft)
                    }
                }
            }
        }
        .chartYScale(domain: 0...(ticks.last ?? 60))
        .chartYAxis {
            AxisMarks(position: .trailing, values: ticks) { value in
                AxisGridLine().foregroundStyle(Theme.inkSoft.opacity(0.25))
                AxisValueLabel {
                    if let minutes = value.as(Double.self) {
                        Text(minutes == 0 ? "0" : AppState.formatDuration(Int(minutes * 60)))
                            .font(Theme.axis)
                            .foregroundStyle(Theme.inkSoft)
                    }
                }
            }
        }
        .chartXSelection(value: Binding(
            get: { selectedDay.map { Self.slots[$0] } },
            set: { selectedDay = $0.flatMap(Int.init) }
        ))
    }
}
