import Foundation
import DaemonKit
import AgenticJobKit

/// Implements DaemonTask for a script-based job.
/// Compilation is lazy — happens inside execute(), not during discovery.
struct ScriptDaemonTask: DaemonTask {
    let descriptor: JobDescriptor
    let compiler: SwiftCompiler
    let loader: JobLoader
    let analytics: any AnalyticsProvider

    var name: String { descriptor.name }

    var schedule: TaskSchedule {
        TaskSchedule(
            intervalSeconds: descriptor.config.intervalSeconds,
            enabled: descriptor.config.enabled,
            timeout: descriptor.config.timeout,
            backoffOnFailure: descriptor.config.backoffOnFailure
        )
    }

    func execute(context: TaskContext) async throws -> TaskResult {
        if compiler.needsCompile(job: descriptor) {
            let start = Date.now
            try compiler.compile(job: descriptor)
            let duration = Date.now.timeIntervalSince(start)
            analytics.track(.jobCompiled(name: name, durationSeconds: duration))
        }

        let request = JobRequest(
            jobName: name,
            jobDirectory: descriptor.directory,
            jobsDirectory: descriptor.directory.deletingLastPathComponent(),
            runReason: context.runReason == .triggered ? .triggered : .scheduled,
            consecutiveFailures: context.consecutiveFailures
        )

        let response = try loader.load(descriptor: descriptor, request: request)

        return TaskResult(
            nextRunSeconds: response.nextRunSeconds,
            nextRunAt: response.nextRunAt,
            trigger: response.trigger,
            enabled: response.enabled,
            message: response.message
        )
    }
}
