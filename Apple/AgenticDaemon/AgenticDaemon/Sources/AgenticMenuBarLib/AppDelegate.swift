import AppKit
import Foundation
import os
import AgenticXPCProtocol
import DaemonKit

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(
        subsystem: "com.agentic-cookbook.daemon",
        category: "MenuBarApp"
    )

    private var statusItem: NSStatusItem!
    private let client = DaemonClient()
    private var menuBuilder: MenuBuilder!
    private var refreshTimer: Timer?
    private var lastStatus: DaemonStatus?
    private var lastCrashes: [CrashReport] = []

    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.title = "⚙"
        statusItem.button?.toolTip = "agentic-daemon"

        menuBuilder = MenuBuilder(handlers: makeHandlers())
        client.connect()

        startRefreshTimer()
        Task { await refresh() }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        client.disconnect()
    }

    // MARK: - Refresh

    private func startRefreshTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    private func refresh() async {
        if !client.isConnected { client.connect() }

        do {
            async let statusFetch = client.getDaemonStatus()
            async let crashFetch  = client.getCrashReports()
            lastStatus = try await statusFetch
            lastCrashes = try await crashFetch
        } catch {
            lastStatus = nil
            lastCrashes = []
        }

        rebuildMenu()
        updateStatusIcon()
    }

    private func rebuildMenu() {
        let menu = menuBuilder.build(status: lastStatus, crashes: lastCrashes)
        statusItem.menu = menu
    }

    private func updateStatusIcon() {
        let hasActiveCrashes = !lastCrashes.isEmpty
        let isDaemonRunning = lastStatus != nil
        if !isDaemonRunning {
            statusItem.button?.title = "⚙"
            statusItem.button?.contentTintColor = .systemRed
        } else if hasActiveCrashes {
            statusItem.button?.title = "⚙"
            statusItem.button?.contentTintColor = .systemOrange
        } else {
            statusItem.button?.title = "⚙"
            statusItem.button?.contentTintColor = nil
        }
    }

    // MARK: - Handlers

    private func makeHandlers() -> MenuBuilder.Handlers {
        MenuBuilder.Handlers(
            onTriggerJob: { [weak self] name in
                Task { @MainActor in
                    try? await self?.client.triggerJob(name)
                    await self?.refresh()
                }
            },
            onEnableJob: { [weak self] name in
                Task { @MainActor in
                    try? await self?.client.enableJob(name)
                    await self?.refresh()
                }
            },
            onDisableJob: { [weak self] name in
                Task { @MainActor in
                    try? await self?.client.disableJob(name)
                    await self?.refresh()
                }
            },
            onClearBlacklist: { [weak self] name in
                Task { @MainActor in
                    try? await self?.client.clearBlacklist(name)
                    await self?.refresh()
                }
            },
            onShowCrash: { report in
                Task { @MainActor in CrashDetailWindow.show(report: report) }
            },
            onStartDaemon: {
                let label = "com.agentic-cookbook.daemon"
                _ = try? Process.run(
                    URL(fileURLWithPath: "/bin/launchctl"),
                    arguments: ["start", label]
                )
            },
            onStopDaemon: { [weak self] in
                Task { @MainActor in try? await self?.client.shutdown() }
            },
            onRestartDaemon: { [weak self] in
                Task { @MainActor in
                    try? await self?.client.shutdown()
                    try? await Task.sleep(for: .seconds(2))
                    let label = "com.agentic-cookbook.daemon"
                    _ = try? Process.run(
                        URL(fileURLWithPath: "/bin/launchctl"),
                        arguments: ["start", label]
                    )
                    self?.client.connect()
                    await self?.refresh()
                }
            },
            onQuit: {
                Task { @MainActor in NSApp.terminate(nil) }
            }
        )
    }
}
