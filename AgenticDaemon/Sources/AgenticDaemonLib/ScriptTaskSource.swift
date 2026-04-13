import Foundation
import DaemonKit

/// Discovers script-based jobs and wraps them as DaemonTasks.
struct ScriptTaskSource: TaskSource {
    let discovery: JobDiscovery
    let compiler: SwiftCompiler
    let loader: JobLoader
    let analytics: any AnalyticsProvider
    let jobsDirectory: URL

    var watchDirectory: URL? { jobsDirectory }

    func discoverTasks() -> [any DaemonTask] {
        discovery.discover().map { descriptor in
            ScriptDaemonTask(
                descriptor: descriptor,
                compiler: compiler,
                loader: loader,
                analytics: analytics
            )
        }
    }

    func shouldClearBlacklist(taskName: String) -> Bool {
        let jobDir = jobsDirectory.appending(path: taskName)
        let sourceURL = jobDir.appending(path: "job.swift")
        let moduleName = taskName.replacingOccurrences(of: "-", with: "_")
        let binaryURL = jobDir.appending(path: "lib\(moduleName).dylib")

        let descriptor = JobDescriptor(
            name: taskName,
            directory: jobDir,
            sourceURL: sourceURL,
            binaryURL: binaryURL,
            config: .default
        )
        return compiler.needsCompile(job: descriptor)
    }
}
