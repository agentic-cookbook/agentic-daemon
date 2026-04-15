import Foundation
import os

public final class DirectoryWatcher: Sendable {
    private let logger: Logger
    private let directory: URL
    private let onChange: @Sendable () -> Void
    private let watcherState = WatcherState()

    public init(directory: URL, subsystem: String, onChange: @escaping @Sendable () -> Void) {
        self.logger = Logger(subsystem: subsystem, category: "DirectoryWatcher")
        self.directory = directory
        self.onChange = onChange
    }

    public func start() {
        let path = directory.path(percentEncoded: false)
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            logger.error("Failed to open directory for watching: \(path)")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: .global(qos: .utility)
        )

        let onChange = self.onChange
        let state = self.watcherState

        source.setEventHandler {
            state.debounce { onChange() }
        }

        source.setCancelHandler { close(fd) }

        state.setSource(source)
        source.resume()
        logger.info("Watching: \(path)")
    }

    public func stop() {
        watcherState.cancel()
        logger.info("Stopped watching")
    }
}

private final class WatcherState: Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var source: DispatchSourceFileSystemObject?
    private nonisolated(unsafe) var debounceWork: DispatchWorkItem?

    func setSource(_ source: DispatchSourceFileSystemObject) {
        lock.withLock { self.source = source }
    }

    func debounce(action: @escaping () -> Void) {
        lock.withLock {
            debounceWork?.cancel()
            let work = DispatchWorkItem(block: action)
            debounceWork = work
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.0, execute: work)
        }
    }

    func cancel() {
        lock.withLock {
            debounceWork?.cancel()
            source?.cancel()
            source = nil
        }
    }
}
