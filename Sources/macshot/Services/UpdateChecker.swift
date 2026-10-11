import Cocoa
import OSLog

/// Asks GitHub for the latest release of this fork and compares it with the running
/// version. It only tells the user: the user downloads the new version and replaces the app.
/// This is the only network request in macshot. It sends nothing about the user or the captures.
final class UpdateChecker {
    nonisolated enum State: Sendable, Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, page: URL)
        case failed(String)
    }

    static let shared = UpdateChecker()
    /// Posted when `state` changes.
    static let didChange = Notification.Name("macshot.updateCheckerDidChange")

    nonisolated static let releasesPage = URL(string: "https://github.com/pgilad/macshot/releases/latest")!
    nonisolated private static let latestRelease = URL(string: "https://api.github.com/repos/pgilad/macshot/releases/latest")!
    // No cookies and no disk cache.
    nonisolated private static let session = URLSession(configuration: .ephemeral)
    /// The least time between two automatic checks that got an answer.
    private static let interval: TimeInterval = 86_400

    private(set) var state = State.idle {
        didSet {
            if state != oldValue {
                NotificationCenter.default.post(name: Self.didChange, object: self)
            }
        }
    }
    let currentVersion: AppVersion?
    /// The request. The tests replace it, so they make no network request.
    private let fetch: (AppVersion?) async -> State
    private var schedule: Task<Void, Never>?

    init(currentVersion: AppVersion? = AppVersion(BuildInfo.version),
         fetch: @escaping (AppVersion?) async -> State = UpdateChecker.fetchState(current:)) {
        self.currentVersion = currentVersion
        self.fetch = fetch
    }

    /// Starts the automatic checks. Each look reads `Preferences.checkForUpdates`, so a
    /// change in Settings, a settings import or `defaults write` needs no restart.
    func start() {
        guard schedule == nil else { return }
        // Look much more often than the interval, so a Mac that was asleep or off checks soon after it has passed.
        schedule = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkIfDue()
                try? await Task.sleep(for: .seconds(3_600))
            }
        }
    }

    /// Checks when automatic checks are on and the last check that got an answer is old enough.
    func checkIfDue() async {
        guard Preferences.checkForUpdates else { return }
        if let last = Preferences.lastUpdateCheck, Date.now.timeIntervalSince(last) < Self.interval {
            return
        }
        await check(showingResult: false)
    }

    /// `showingResult`: show the result in an alert (Check for Updates… in a menu).
    /// Otherwise only `state` changes: Settings and the menu bar menu show it.
    func check(showingResult: Bool) async {
        guard state != .checking else { return }
        state = .checking
        state = await fetch(currentVersion)
        // Only a check that got an answer counts. After a failure (for example no network
        // just after login), the automatic check tries again at the next look.
        switch state {
        case .upToDate, .available:
            Preferences.lastUpdateCheck = .now
        case .idle, .checking, .failed:
            break
        }
        if showingResult {
            showResult()
        }
    }

    /// One line for Settings.
    var statusText: String {
        switch state {
        case .idle:
            Preferences.lastUpdateCheck.map { "Last checked \($0.formatted(date: .abbreviated, time: .shortened))." }
                ?? "Not checked yet."
        case .checking: "Checking…"
        case .upToDate: "macshot \(currentVersion?.description ?? "") is up to date."
        case .available(let version, _): "macshot \(version) is available."
        case .failed(let message): message
        }
    }

    /// The title of Check for Updates… in the menu bar menu. It names a new version that a check found.
    var menuTitle: String {
        if case .available(let version, _) = state {
            return "macshot \(version) Is Available…"
        }
        return "Check for Updates…"
    }

    @concurrent
    nonisolated static func fetchState(current: AppVersion?) async -> State {
        guard let current else {
            return .failed("This build has no version number.")
        }
        var request = URLRequest(url: latestRelease, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        do {
            let (data, response) = try await session.data(for: request)
            return state(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data, current: current)
        } catch {
            Log.app.error("Update check failed: \(error.localizedDescription, privacy: .public)")
            return .failed("Cannot reach GitHub: \(error.localizedDescription)")
        }
    }

    /// The result of an answer from GitHub.
    nonisolated static func state(status: Int, body: Data, current: AppVersion) -> State {
        switch status {
        case 200: break
        // Without a token, GitHub limits the requests from one IP address (see its rate limit headers).
        case 403, 429: return .failed("GitHub limits the number of checks. Try again in an hour.")
        case 404: return .failed("GitHub has no release of macshot.")
        default: return .failed("GitHub returned HTTP \(status).")
        }
        guard let release = try? JSONDecoder().decode(GitHubRelease.self, from: body) else {
            return .failed("GitHub sent an answer that macshot cannot read.")
        }
        guard let latest = release.version else {
            return .failed("The latest release has an unknown version: \(release.tagName).")
        }
        return latest > current ? .available(version: latest.description, page: release.pageURL ?? releasesPage) : .upToDate
    }

    private func showResult() {
        let alert = NSAlert()
        let current = currentVersion?.description ?? "unknown"
        var page: URL?
        switch state {
        case .available(let version, let releasePage):
            page = releasePage
            alert.messageText = "macshot \(version) Is Available"
            alert.informativeText = "You have macshot \(current). Download the new version from GitHub, quit macshot and replace the app."
            alert.addButton(withTitle: "Open Release Page")
            alert.addButton(withTitle: "Later")
        case .upToDate:
            alert.messageText = "macshot Is Up to Date"
            alert.informativeText = "macshot \(current) is the latest version."
        case .failed(let message):
            alert.messageText = "Cannot Check for Updates"
            alert.informativeText = message
            alert.alertStyle = .warning
        case .idle, .checking:
            return
        }
        // The check can end after the menu closed, when another app is active.
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn, let page {
            NSWorkspace.shared.open(page)
        }
    }
}
