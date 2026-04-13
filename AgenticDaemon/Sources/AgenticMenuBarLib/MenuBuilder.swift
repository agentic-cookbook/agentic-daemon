import AppKit
import Foundation
import AgenticXPCProtocol
import DaemonKit

/// Builds an NSMenu from the latest DaemonStatus and crash list.
/// Stateless — build(status:crashes:) can be called on every refresh.
public final class MenuBuilder: @unchecked Sendable {

    public struct Handlers: Sendable {
        public let onTriggerJob: @Sendable (String) -> Void
        public let onEnableJob: @Sendable (String) -> Void
        public let onDisableJob: @Sendable (String) -> Void
        public let onClearBlacklist: @Sendable (String) -> Void
        public let onShowCrash: @Sendable (CrashReport) -> Void
        public let onStartDaemon: @Sendable () -> Void
        public let onStopDaemon: @Sendable () -> Void
        public let onRestartDaemon: @Sendable () -> Void
        public let onQuit: @Sendable () -> Void

        public init(
            onTriggerJob: @escaping @Sendable (String) -> Void,
            onEnableJob: @escaping @Sendable (String) -> Void,
            onDisableJob: @escaping @Sendable (String) -> Void,
            onClearBlacklist: @escaping @Sendable (String) -> Void,
            onShowCrash: @escaping @Sendable (CrashReport) -> Void,
            onStartDaemon: @escaping @Sendable () -> Void,
            onStopDaemon: @escaping @Sendable () -> Void,
            onRestartDaemon: @escaping @Sendable () -> Void,
            onQuit: @escaping @Sendable () -> Void
        ) {
            self.onTriggerJob = onTriggerJob
            self.onEnableJob = onEnableJob
            self.onDisableJob = onDisableJob
            self.onClearBlacklist = onClearBlacklist
            self.onShowCrash = onShowCrash
            self.onStartDaemon = onStartDaemon
            self.onStopDaemon = onStopDaemon
            self.onRestartDaemon = onRestartDaemon
            self.onQuit = onQuit
        }
    }

    private let handlers: Handlers

    public init(handlers: Handlers) {
        self.handlers = handlers
    }

    public func build(status: DaemonStatus?, crashes: [CrashReport]) -> NSMenu {
        let menu = NSMenu()

        if let status {
            addHeader(menu, status: status)
            menu.addItem(.separator())
            addJobsSection(menu, jobs: status.jobs)
            menu.addItem(.separator())
            if !crashes.isEmpty {
                addCrashesSection(menu, crashes: crashes)
                menu.addItem(.separator())
            }
            addDaemonControls(menu, running: true)
        } else {
            addStoppedHeader(menu)
            menu.addItem(.separator())
            menu.addItem(menuItem("Start Daemon", action: handlers.onStartDaemon))
        }

        menu.addItem(.separator())
        menu.addItem(menuItem("Quit", action: handlers.onQuit))
        return menu
    }

    // MARK: - Sections

    private func addHeader(_ menu: NSMenu, status: DaemonStatus) {
        let title = "agentic-daemon  ·  uptime \(formatUptime(status.uptimeSeconds))"
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addStoppedHeader(_ menu: NSMenu) {
        let item = NSMenuItem(title: "● Daemon not running", action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addJobsSection(_ menu: NSMenu, jobs: [DaemonStatus.JobStatus]) {
        let header = NSMenuItem(title: "JOBS (\(jobs.count))", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        for job in jobs.sorted(by: { $0.name < $1.name }) {
            menu.addItem(makeJobItem(job))
        }
    }

    private func addCrashesSection(_ menu: NSMenu, crashes: [CrashReport]) {
        let header = NSMenuItem(title: "RECENT CRASHES (\(crashes.count))", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        for crash in crashes.prefix(5) {
            menu.addItem(makeCrashItem(crash))
        }
    }

    private func addDaemonControls(_ menu: NSMenu, running: Bool) {
        menu.addItem(menuItem("Restart Daemon", action: handlers.onRestartDaemon))
        menu.addItem(menuItem("Stop Daemon", action: handlers.onStopDaemon))
    }

    // MARK: - Job Items

    private func makeJobItem(_ job: DaemonStatus.JobStatus) -> NSMenuItem {
        let dot = job.isRunning ? "●" : (job.config.enabled ? "●" : "○")
        let nextRunText: String
        if job.isRunning {
            nextRunText = "running…"
        } else if !job.config.enabled {
            nextRunText = "disabled"
        } else {
            let secs = Int(max(0, job.nextRun.timeIntervalSinceNow))
            nextRunText = secs < 60 ? "next: \(secs)s" : "next: \(secs / 60)m"
        }

        let item = NSMenuItem(title: "\(dot) \(job.name)   \(nextRunText)", action: nil, keyEquivalent: "")
        item.submenu = makeJobSubmenu(job)
        return item
    }

    private func makeJobSubmenu(_ job: DaemonStatus.JobStatus) -> NSMenu {
        let menu = NSMenu()

        let titleItem = NSMenuItem(title: job.name, action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        let subtitle: String
        if job.isRunning {
            subtitle = "Currently running"
        } else if !job.config.enabled {
            subtitle = "Disabled"
        } else {
            let secs = Int(max(0, job.nextRun.timeIntervalSinceNow))
            subtitle = "Next run in \(secs < 60 ? "\(secs)s" : "\(secs / 60)m \(secs % 60)s")"
        }
        let subtitleItem = NSMenuItem(title: subtitle, action: nil, keyEquivalent: "")
        subtitleItem.isEnabled = false
        menu.addItem(subtitleItem)
        menu.addItem(.separator())

        // Config
        addLabel(menu, "CONFIG")
        addInfo(menu, label: "Interval", value: "\(Int(job.config.intervalSeconds))s")
        addInfo(menu, label: "Timeout", value: "\(Int(job.config.timeout))s")
        addInfo(menu, label: "Run at wake", value: job.config.runAtWake ? "Yes" : "No")
        addInfo(menu, label: "Backoff", value: job.config.backoffOnFailure ? "Yes" : "No")
        menu.addItem(.separator())

        // Runtime
        addLabel(menu, "RUNTIME")
        addInfo(menu, label: "Failures", value: "\(job.consecutiveFailures)")
        addInfo(menu, label: "Blacklisted", value: job.isBlacklisted ? "Yes" : "No")
        menu.addItem(.separator())

        // Actions
        menu.addItem(menuItem("Trigger Now", action: { [handlers] in handlers.onTriggerJob(job.name) }))
        if job.config.enabled {
            menu.addItem(menuItem("Disable Job", action: { [handlers] in handlers.onDisableJob(job.name) }))
        } else {
            menu.addItem(menuItem("Enable Job", action: { [handlers] in handlers.onEnableJob(job.name) }))
        }
        if job.isBlacklisted {
            menu.addItem(menuItem("Clear Blacklist", action: { [handlers] in handlers.onClearBlacklist(job.name) }))
        }

        return menu
    }

    // MARK: - Crash Items

    private func makeCrashItem(_ crash: CrashReport) -> NSMenuItem {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        let ago = formatter.localizedString(for: crash.timestamp, relativeTo: Date.now)
        let exc = crash.exceptionType ?? crash.signal ?? "unknown"
        let title = "⚠ \(crash.taskName) — \(ago)   \(exc)"
        return menuItem(title, action: { [handlers] in handlers.onShowCrash(crash) })
    }

    // MARK: - Helpers

    private func addLabel(_ menu: NSMenu, _ text: String) {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addInfo(_ menu: NSMenu, label: String, value: String) {
        let item = NSMenuItem(title: "\(label):  \(value)", action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.indentationLevel = 1
        menu.addItem(item)
    }

    private func menuItem(_ title: String, action: @escaping @Sendable () -> Void) -> NSMenuItem {
        BlockMenuItem(title: title, action: action)
    }

    private func formatUptime(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \(s % 3600 / 60)m"
    }
}

/// NSMenuItem subclass that holds an action closure.
/// Required because NSMenuItem target/action needs an @objc method on an NSObject.
private final class BlockMenuItem: NSMenuItem {
    private let block: @Sendable () -> Void

    init(title: String, action block: @escaping @Sendable () -> Void) {
        self.block = block
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        self.target = self
    }

    required init(coder: NSCoder) { fatalError("not implemented") }

    @objc private func invoke() { block() }
}
