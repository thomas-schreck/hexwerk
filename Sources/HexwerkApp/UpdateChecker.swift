import AppKit
import HexwerkCore

/// Asks GitHub for the latest release (#119): automatically at most once a
/// day unless `checkForUpdates` is off, and from "Check for Updates…". Sends
/// no personal data, only a User-Agent with the version; never downloads.
/// This file is the only place in hexwerk that uses the network.
@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()

    /// Settings keys in settings.json.
    static let enabledKey = "checkForUpdates"
    static let lastCheckKey = "lastUpdateCheck"
    static let latestTagKey = "latestReleaseTag"
    static let latestPageKey = "latestReleasePage"

    /// Hidden until a newer release is known; opens its page.
    let menuItem: NSMenuItem = {
        let item = NSMenuItem(title: "", action: #selector(UpdateChecker.showRelease(_:)), keyEquivalent: "")
        item.isHidden = true
        return item
    }()

    private(set) var release: UpdateCheck.Release?
    private var running = false
    private let version = BuildInfo.current.version

    private init() {
        menuItem.target = self
    }

    var isEnabled: Bool {
        get { Settings.shared.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { Settings.shared.set(newValue, forKey: Self.enabledKey) }
    }

    /// At launch: show a release found earlier, then check if due.
    func start() {
        guard UpdateCheck.comparableVersion(version) != nil else { return }
        if isEnabled {
            show(
                UpdateCheck.pendingRelease(
                    tag: Settings.shared.string(forKey: Self.latestTagKey),
                    page: Settings.shared.string(forKey: Self.latestPageKey), running: version))
        }
        let last = (Settings.shared.object(forKey: Self.lastCheckKey) as? Double).map(Date.init(timeIntervalSince1970:))
        guard UpdateCheck.shouldCheck(running: version, enabled: isEnabled, lastCheck: last) else { return }
        Task { _ = await check() }
    }

    /// "Check for Updates…": checks now and reports the result.
    func checkManually() {
        guard UpdateCheck.comparableVersion(version) != nil else {
            report(L("Update checks are not available for development builds."), nil)
            return
        }
        Task {
            switch await check() {
            case .some(.success(let r?)):
                let a = NSAlert()
                a.messageText = L("hexwerk %@ is available.", r.version.description)
                a.informativeText = L("You are using version %@.", version)
                a.addButton(withTitle: L("Show Release"))
                a.addButton(withTitle: L("Later"))
                if a.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(r.page) }
            case .some(.success(nil)):
                report(L("hexwerk %@ is up to date.", version), nil)
            case .some(.failure(let e)):
                report(L("The update check failed."), e.localizedDescription)
            case nil:
                break  // a check is already running
            }
        }
    }

    /// One request; nil when a check is already running.
    private func check() async -> Result<UpdateCheck.Release?, Error>? {
        guard !running else { return nil }
        running = true
        defer { running = false }
        Settings.shared.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
        do {
            let found = try await fetch()
            Settings.shared.set(found.map { "v\($0.version)" }, forKey: Self.latestTagKey)
            Settings.shared.set(found?.page.absoluteString, forKey: Self.latestPageKey)
            show(found)
            return .success(found)
        } catch {
            return .failure(error)
        }
    }

    private func fetch() async throws -> UpdateCheck.Release? {
        var request = URLRequest(url: UpdateCheck.latestReleaseAPI, timeoutInterval: 10)
        request.setValue("hexwerk/\(version)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let config = URLSessionConfiguration.ephemeral  // no cookies, no cache
        config.timeoutIntervalForResource = 15
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode {
        case 200: break
        case 404: return nil  // no published release yet, only pre-releases
        default: throw URLError(.badServerResponse)
        }
        return try UpdateCheck.newerRelease(in: data, running: version)
    }

    private func show(_ release: UpdateCheck.Release?) {
        self.release = release
        menuItem.isHidden = release == nil
        if let release { menuItem.title = L("Update Available: %@…", release.version.description) }
    }

    @objc func showRelease(_ sender: Any?) {
        if let release { NSWorkspace.shared.open(release.page) }
    }

    private func report(_ message: String, _ info: String?) {
        let a = NSAlert()
        a.messageText = message
        if let info { a.informativeText = info }
        a.runModal()
    }
}
