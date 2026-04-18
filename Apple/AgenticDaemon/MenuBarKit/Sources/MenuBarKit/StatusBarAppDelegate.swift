import AppKit
import Foundation
import DaemonKit

/// Generic status-bar app driver. Polls the daemon's `/health` on a timer,
/// assembles a menu via ``MenuComposer``, and keeps an `NSStatusItem`
/// up-to-date.
///
/// Typical `main.swift`:
///
///     let delegate = StatusBarAppDelegate(
///         http: DaemonHTTPClient(baseURL: "http://127.0.0.1:22847"),
///         menuIcon: "⚙",
///         composer: MenuComposer(sections: [
///             HealthMenuSection(daemonName: "mydaemon"),
///             TimingStrategyMenuSection(onTrigger: { /* XPC call */ }),
///             ControlsMenuSection(onQuit: { NSApp.terminate(nil) })
///         ])
///     )
///     let app = NSApplication.shared
///     app.delegate = delegate
///     app.setActivationPolicy(.accessory)
///     app.run()
@MainActor
public final class StatusBarAppDelegate: NSObject, NSApplicationDelegate {
    private let http: DaemonHTTPClient
    private let composer: MenuComposer
    private let menuIcon: String
    private let menuImage: NSImage?
    private let refreshInterval: TimeInterval
    private let userInfoProvider: (@Sendable (DaemonHTTPClient) async -> [String: any Sendable])?

    private var statusItem: NSStatusItem?
    private var timer: Timer?

    public init(
        http: DaemonHTTPClient,
        composer: MenuComposer,
        menuIcon: String = "⚙",
        menuImage: NSImage? = nil,
        refreshInterval: TimeInterval = 5,
        userInfoProvider: (@Sendable (DaemonHTTPClient) async -> [String: any Sendable])? = nil
    ) {
        self.http = http
        self.composer = composer
        self.menuIcon = menuIcon
        self.menuImage = menuImage
        self.refreshInterval = refreshInterval
        self.userInfoProvider = userInfoProvider
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let menuImage {
            item.button?.image = menuImage
        } else {
            item.button?.title = menuIcon
        }
        item.menu = composer.build(snapshot: MenuSnapshot(isReachable: false))
        self.statusItem = item

        refresh()

        let timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    public func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }

    /// Force a refresh. Safe to call from tests via a direct-constructed
    /// delegate (without launching the app).
    public func refresh() {
        let http = self.http
        let composer = self.composer
        let userInfoProvider = self.userInfoProvider
        Task { [weak self] in
            let health = http.get("/health", as: HealthStatus.self)
            let userInfo: [String: any Sendable] = await userInfoProvider?(http) ?? [:]
            await MainActor.run { [weak self] in
                guard let self else { return }
                let snapshot = MenuSnapshot(
                    isReachable: health != nil,
                    health: health,
                    userInfo: userInfo
                )
                self.statusItem?.menu = composer.build(snapshot: snapshot)
                self.updateIcon(isReachable: health != nil)
            }
        }
    }

    private func updateIcon(isReachable: Bool) {
        guard let button = statusItem?.button else { return }
        if let menuImage {
            button.image = menuImage
            button.title = ""
        } else {
            button.title = isReachable ? menuIcon : "●"
        }
    }
}
