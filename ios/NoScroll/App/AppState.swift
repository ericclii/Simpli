import Foundation
import SwiftUI
import UIKit
import WebKit

/// App-wide state: the verified rule bundles, the engine source, per-surface
/// user settings, accounts, and which services the home screen shows.
@MainActor
final class AppState: ObservableObject {

    @Published private(set) var bundles: [String: RuleBundle] = [:]
    @Published private(set) var rawBundles: [String: Data] = [:]
    @Published var settings: [String: Bool] = [:] {
        didSet { persistSettings() }
    }

    private(set) var engineSource = ""

    private let settingsKey = "noscroll.settings"

    // MARK: - Accounts

    /// Every signed-in account, across services. Each has its own persistent
    /// WKWebsiteDataStore (cookies, storage) and its own saved page, keyed by
    /// its id, so accounts never share a session.
    @Published private(set) var accounts: [WebSession] = [] {
        didSet { persist(accounts, forKey: "noscroll.accounts") }
    }
    /// The account each service opens with.
    @Published private(set) var activeAccountIDs: [String: UUID] = [:] {
        didSet { persist(activeAccountIDs, forKey: "noscroll.activeAccounts") }
    }

    func accounts(for service: String) -> [WebSession] {
        accounts.filter { $0.service == service }
    }

    func activeAccount(for service: String) -> WebSession {
        let mine = accounts(for: service)
        if let id = activeAccountIDs[service], let active = mine.first(where: { $0.id == id }) { return active }
        return mine.first ?? WebSession(id: Self.defaultSessionID(for: service), service: service, displayName: "")
    }

    func selectAccount(_ account: WebSession) {
        activeAccountIDs[account.service] = account.id
    }

    /// A new, empty account: it opens on the service's sign-in page.
    @discardableResult
    func addAccount(for service: String) -> WebSession {
        let account = WebSession(id: UUID(), service: service, displayName: "")
        accounts.append(account)
        selectAccount(account)
        return account
    }

    /// Signs the account out on this device: its cookies and storage are
    /// deleted, not just forgotten, so a later account can't inherit them.
    /// A service always keeps at least one (then empty) account.
    func removeAccount(_ account: WebSession) async {
        accounts.removeAll { $0.id == account.id }
        let stateKey = "noscroll.state.\(account.id.uuidString)"
        UserDefaults.standard.removeObject(forKey: stateKey)
        UserDefaults.standard.removeObject(forKey: stateKey + ".url")
        try? await WKWebsiteDataStore.remove(forIdentifier: account.id)
        if activeAccountIDs[account.service] == account.id {
            activeAccountIDs[account.service] = accounts(for: account.service).first?.id
        }
        if accounts(for: account.service).isEmpty { addAccount(for: account.service) }
    }

    /// Called with the username the page shows for the signed-in account.
    func setUsername(_ username: String, for accountID: UUID) {
        guard let i = accounts.firstIndex(where: { $0.id == accountID }),
              accounts[i].displayName != username else { return }
        accounts[i].displayName = username
    }

    /// How an account is shown: its username once known, otherwise its place
    /// in the list.
    func label(for account: WebSession) -> String {
        if !account.displayName.isEmpty { return "@\(account.displayName)" }
        let index = accounts(for: account.service).firstIndex(of: account) ?? 0
        return "Account \(index + 1)"
    }

    /// The first account of every service reuses the identifier the app has
    /// always used for that service, so existing sign-ins carry over.
    ///
    /// Derived from the service id rather than a hand-maintained table: the
    /// table listed two services and gave every other one the same UUID, which
    /// meant six services shared a single cookie jar.
    static func defaultSessionID(for service: String) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        for (i, byte) in Array(service.utf8).enumerated() {
            bytes[i % 16] = bytes[i % 16] &+ byte &* UInt8(truncatingIfNeeded: i &+ 1)
        }
        // Stamp RFC-4122 version/variant bits so it is a well-formed UUID.
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5],
                           bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private func loadAccounts() {
        let defaults = UserDefaults.standard
        var loaded = (defaults.data(forKey: "noscroll.accounts"))
            .flatMap { try? JSONDecoder().decode([WebSession].self, from: $0) } ?? []
        for service in Self.services where !loaded.contains(where: { $0.service == service.id }) {
            loaded.append(WebSession(id: Self.defaultSessionID(for: service.id), service: service.id, displayName: ""))
        }
        accounts = loaded
        activeAccountIDs = (defaults.data(forKey: "noscroll.activeAccounts"))
            .flatMap { try? JSONDecoder().decode([String: UUID].self, from: $0) } ?? [:]
    }

    private func persist(_ value: some Encodable, forKey key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }

    // MARK: - Home screen

    /// Services the user removed from the home screen carousel. Their settings
    /// and sessions are kept, so showing one again restores it as it was.
    /// Until the user changes it, only Instagram and YouTube are shown.
    @Published private(set) var hiddenServices: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "noscroll.hiddenServices")
            ?? AppState.services.map(\.id).filter { !["instagram", "youtube"].contains($0) }) {
        didSet { UserDefaults.standard.set(Array(hiddenServices).sorted(), forKey: "noscroll.hiddenServices") }
    }

    /// Services shown in the home screen carousel, in their usual order.
    var visibleServices: [Service] {
        Self.services.filter { !hiddenServices.contains($0.id) }
    }

    func showOnHome(_ serviceID: String) -> Binding<Bool> {
        Binding(
            get: { [weak self] in !(self?.hiddenServices.contains(serviceID) ?? false) },
            set: { [weak self] shown in
                if shown { self?.hiddenServices.remove(serviceID) } else { self?.hiddenServices.insert(serviceID) }
            }
        )
    }

    // MARK: - Usage

    /// Seconds each service has been open in NoScroll, per day, measured by
    /// WebScreen while it is on screen and the app is active. A day runs from
    /// 4 AM to 4 AM, so late-night use counts toward the day it started.
    /// Kept on this device only, for this week and last week.
    @Published private(set) var usageHistory: [String: [String: Int]] = [:]
    private let usageKey = "noscroll.usageHistory"
    static let dayStartHour = 4

    func addUsage(_ seconds: TimeInterval, for serviceID: String) {
        guard seconds > 0 else { return }
        let day = Self.key(ofDay: Self.usageDay(for: Date()))
        usageHistory[day, default: [:]][serviceID, default: 0] += Int(seconds.rounded())
        pruneUsage()
        UserDefaults.standard.set(usageHistory, forKey: usageKey)
    }

    /// Records that the app was used today, even if no service was opened, so
    /// today counts as "0m" rather than "no data" (a day before the app was
    /// installed, or one it wasn't opened). Averages only count days with data.
    func markDayActive() {
        let day = Self.key(ofDay: Self.usageDay(for: Date()))
        guard usageHistory[day] == nil else { return }
        usageHistory[day] = [:]
        pruneUsage()
        UserDefaults.standard.set(usageHistory, forKey: usageKey)
    }

    /// Whether anything was recorded for this calendar day (see markDayActive).
    func hasUsageData(on day: Date) -> Bool {
        usageHistory[Self.key(ofDay: day)] != nil
    }

    /// Only this week and last week are kept: what the Screen Time tab shows.
    private func pruneUsage() {
        let oldest = Self.key(ofDay: Self.week(offset: -1)[0])
        usageHistory = usageHistory.filter { $0.key >= oldest }
    }

    /// `day` is a calendar day (from `usageDay` or `week`), not a moment.
    func usageSeconds(on day: Date, for serviceID: String) -> Int {
        usageHistory[Self.key(ofDay: day)]?[serviceID] ?? 0
    }

    /// Today's time in a service: "0m", "12m", "1h 5m".
    func usageToday(for serviceID: String) -> String {
        Self.formatDuration(usageSeconds(on: Self.usageDay(for: Date()), for: serviceID))
    }

    /// "0m", "45m", "1h", "1h 5m".
    static func formatDuration(_ seconds: Int) -> String {
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
    }

    /// The calendar day a moment is counted toward (before 4 AM → yesterday).
    static func usageDay(for date: Date) -> Date {
        let shifted = date.addingTimeInterval(-TimeInterval(dayStartHour) * 3600)
        return Calendar.current.startOfDay(for: shifted)
    }

    /// Storage key of a calendar day. No 4 AM shift here: that belongs to
    /// turning a moment into a day (`usageDay`), and applying it to a day
    /// that is already a midnight would land on the previous date.
    static func key(ofDay day: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The seven days (Sunday first) of this week (offset 0) or an earlier one.
    static func week(offset: Int) -> [Date] {
        let cal = Calendar(identifier: .gregorian)
        let today = usageDay(for: Date())
        let sunday = cal.date(byAdding: .day, value: 1 - cal.component(.weekday, from: today), to: today)!
        let start = cal.date(byAdding: .day, value: 7 * offset, to: sunday)!
        return (0..<7).map { cal.date(byAdding: .day, value: $0, to: start)! }
    }

    private func loadUsage() {
        let defaults = UserDefaults.standard
        usageHistory = defaults.dictionary(forKey: usageKey) as? [String: [String: Int]] ?? [:]
        // Carry over the single-day format used before history was kept.
        if let old = defaults.dictionary(forKey: "noscroll.usage"),
           let day = old["day"] as? String, let seconds = old["seconds"] as? [String: Int] {
            usageHistory[day, default: [:]].merge(seconds) { max($0, $1) }
            defaults.set(usageHistory, forKey: usageKey)
            defaults.removeObject(forKey: "noscroll.usage")
        }
        pruneUsage()
        defaults.set(usageHistory, forKey: usageKey)
    }

    // MARK: - Navigation

    enum Tab: Hashable { case adjust, home, usage }
    @Published var tab: Tab = .home
    /// Set by a widget tap; HomeView opens this service's browser.
    @Published var pendingService: String?

    /// noscroll://open/<service> — the widget's whole job.
    func handle(url: URL) {
        guard url.scheme == "noscroll", url.host == "open" else { return }
        let id = url.lastPathComponent
        guard Self.service(id) != nil else { return }
        tab = .home
        pendingService = id
    }

    init() {
        loadAccounts()
        loadUsage()
        loadSettings()
        loadEngine()
        loadBundles()
        seedDefaults()

    }

    /// Materialise each surface's default so Settings shows real switch
    /// positions rather than a screen of greyed-out unknowns.
    private func seedDefaults() {
        for service in Self.services {
            guard let svc = bundles[service.id]?.services[service.id] else { continue }
            for (name, surface) in svc.surfaces where surface.label != nil {
                let key = "\(service.id).\(name)"
                if settings[key] == nil { settings[key] = surface.defaultEnabled ?? false }
            }
        }
    }

    // MARK: - Loading

    private func loadEngine() {
        guard let url = Bundle.main.url(forResource: "noscroll", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else { return }
        engineSource = source
    }

    /// Bundles are ed25519-signed and verified here, before anything is
    /// injected. One that fails is refused outright: better to show nothing
    /// (WebScreen says "Rules unavailable") than to browse with blocking off.
    private func loadBundles() {
        guard let keyURL = Bundle.main.url(forResource: "rules-signing.pub", withExtension: "raw"),
              let keyData = try? Data(contentsOf: keyURL),
              let verifier = try? RuleVerifier(publicKeyRaw: keyData) else { return }

        for service in Self.services {
            guard let url = Bundle.main.url(forResource: service.id, withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let bundle = try? verifier.verify(data) else { continue }
            bundles[service.id] = bundle
            rawBundles[service.id] = data
        }
    }

    // MARK: - Settings

    /// One switch may drive several surfaces. "Block Reels" is both a DOM rule
    /// (the nav icon) and a route rule (typing the URL); the user thinks of that
    /// as one thing, so surfaces sharing a label are presented as one toggle.
    func binding(service: String, surfaces keys: [String]) -> Binding<Bool> {
        Binding(
            get: { [weak self] in
                guard let self else { return false }
                return keys.contains { key in
                    if let v = self.settings["\(service).\(key)"] { return v }
                    return self.bundles[service]?.services[service]?
                        .surfaces[key]?.defaultEnabled ?? false
                }
            },
            set: { [weak self] newValue in
                guard let self else { return }
                for key in keys { self.settings["\(service).\(key)"] = newValue }
            }
        )
    }

    /// Surfaces in a stable, human order. Suggested-on ones sort first so the
    /// list reads as "here is what we recommend", then the extras.
    struct SurfaceGroup: Identifiable {
        let label: String
        let keys: [String]
        let suggested: Bool
        var id: String { label }
    }

    func surfaces(for service: String) -> [SurfaceGroup] {
        guard let svc = bundles[service]?.services[service] else { return [] }
        var byLabel: [String: (keys: [String], suggested: Bool)] = [:]
        for (key, surface) in svc.surfaces {
            guard let label = surface.label else { continue }
            var entry = byLabel[label] ?? (keys: [], suggested: false)
            entry.keys.append(key)
            entry.suggested = entry.suggested || (surface.defaultEnabled ?? false)
            byLabel[label] = entry
        }
        return byLabel
            .map { SurfaceGroup(label: $0.key, keys: $0.value.keys.sorted(), suggested: $0.value.suggested) }
            .sorted { lhs, rhs in
                if lhs.suggested != rhs.suggested { return lhs.suggested && !rhs.suggested }
                return lhs.label < rhs.label
            }
    }

    private func loadSettings() {
        settings = UserDefaults.standard.dictionary(forKey: settingsKey) as? [String: Bool] ?? [:]
    }

    private func persistSettings() {
        UserDefaults.standard.set(settings, forKey: settingsKey)
    }
}
