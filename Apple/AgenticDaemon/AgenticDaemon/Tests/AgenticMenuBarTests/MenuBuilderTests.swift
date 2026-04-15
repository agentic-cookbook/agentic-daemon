import Testing
import AppKit
import Foundation
import AgenticXPCProtocol
import DaemonKit
@testable import AgenticMenuBarLib

@Suite("MenuBuilder")
struct MenuBuilderTests {

    let noopHandlers = MenuBuilder.Handlers(
        onTriggerJob: { _ in },
        onEnableJob: { _ in },
        onDisableJob: { _ in },
        onClearBlacklist: { _ in },
        onShowCrash: { _ in },
        onStartDaemon: {},
        onStopDaemon: {},
        onRestartDaemon: {},
        onQuit: {}
    )

    @Test("nil status shows stopped state with Start Daemon item")
    func nilStatusShowsStoppedState() {
        let builder = MenuBuilder(handlers: noopHandlers)
        let menu = builder.build(status: nil, crashes: [])
        let titles = menu.items.map(\.title)
        #expect(titles.contains { $0.localizedCaseInsensitiveContains("not running") })
        #expect(titles.contains("Start Daemon"))
        #expect(!titles.contains("Stop Daemon"))
    }

    @Test("running status shows job rows")
    func runningStatusShowsJobs() {
        let status = makeStatus(jobs: [
            makeJobStatus(name: "cleanup"),
            makeJobStatus(name: "sync", isRunning: true)
        ])
        let builder = MenuBuilder(handlers: noopHandlers)
        let menu = builder.build(status: status, crashes: [])
        let allTitles = collectAllTitles(menu)
        #expect(allTitles.contains { $0.contains("cleanup") })
        #expect(allTitles.contains { $0.contains("sync") })
    }

    @Test("crashes section appears only when crashes exist")
    func crashesSectionVisibility() {
        let status = makeStatus(jobs: [])
        let builder = MenuBuilder(handlers: noopHandlers)

        let menuWithout = builder.build(status: status, crashes: [])
        #expect(!menuWithout.items.map(\.title).contains { $0.contains("CRASH") })

        let crash = CrashReport(
            taskName: "sync",
            timestamp: Date.now.addingTimeInterval(-3600),
            signal: nil,
            exceptionType: "EXC_BAD_ACCESS",
            faultingThread: nil,
            stackTrace: nil,
            source: .plcrash
        )
        let menuWith = builder.build(status: status, crashes: [crash])
        let titles = menuWith.items.map(\.title)
        #expect(titles.contains { $0.contains("CRASH") })
        #expect(collectAllTitles(menuWith).contains { $0.contains("sync") })
    }

    @Test("Quit item is always present")
    func quitAlwaysPresent() {
        let builder = MenuBuilder(handlers: noopHandlers)
        #expect(builder.build(status: nil, crashes: []).items.map(\.title).contains("Quit"))
        #expect(builder.build(status: makeStatus(jobs: []), crashes: []).items.map(\.title).contains("Quit"))
    }

    @Test("running status shows Stop Daemon, not Start Daemon")
    func runningDaemonShowsStopNotStart() {
        let builder = MenuBuilder(handlers: noopHandlers)
        let menu = builder.build(status: makeStatus(jobs: []), crashes: [])
        let titles = menu.items.map(\.title)
        #expect(titles.contains("Stop Daemon"))
        #expect(!titles.contains("Start Daemon"))
    }

    @Test("job submenu contains config and control items")
    func jobSubmenuContents() {
        let config = JobConfig(intervalSeconds: 120, enabled: false, timeout: 45, runAtWake: false, backoffOnFailure: false)
        let status = makeStatus(jobs: [makeJobStatus(name: "worker", config: config, isBlacklisted: true)])
        let builder = MenuBuilder(handlers: noopHandlers)
        let menu = builder.build(status: status, crashes: [])

        let jobItem = menu.items.first { $0.submenu != nil && $0.title.contains("worker") }
        let submenuTitles = jobItem?.submenu?.items.map(\.title) ?? []

        #expect(submenuTitles.contains { $0.contains("120") })   // interval
        #expect(submenuTitles.contains { $0.contains("45") })    // timeout
        #expect(submenuTitles.contains("Trigger Now"))
        #expect(submenuTitles.contains("Enable Job"))            // disabled → enable (blacklisted means disabled here)
        #expect(submenuTitles.contains("Clear Blacklist"))
    }
}

// MARK: - Helpers

private func makeStatus(jobs: [DaemonStatus.JobStatus]) -> DaemonStatus {
    DaemonStatus(uptimeSeconds: 60, jobCount: jobs.count, lastTick: Date.now, jobs: jobs)
}

private func makeJobStatus(
    name: String,
    config: JobConfig = .default,
    isRunning: Bool = false,
    isBlacklisted: Bool = false
) -> DaemonStatus.JobStatus {
    DaemonStatus.JobStatus(
        name: name,
        nextRun: Date.now.addingTimeInterval(60),
        consecutiveFailures: 0,
        isRunning: isRunning,
        config: config,
        isBlacklisted: isBlacklisted
    )
}

/// Collect titles from the menu and all submenus.
private func collectAllTitles(_ menu: NSMenu) -> [String] {
    menu.items.flatMap { item -> [String] in
        var titles = [item.title]
        if let sub = item.submenu {
            titles += collectAllTitles(sub)
        }
        return titles
    }
}
