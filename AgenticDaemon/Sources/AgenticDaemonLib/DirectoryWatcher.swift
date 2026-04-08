import Foundation
import os

final class DirectoryWatcher: Sendable {
    private let logger = Logger(
        subsystem: "com.agentic-cookbook.daemon",
        category: "DirectoryWatcher"
    )
    private let directory: URL
    private let onChange: @Sendable () -> Void

    private let watcherState = WatcherState()

    init(directory: URL, onChange: @escaping @Sendable () -> Void) {
        self.directory = directory
        self.onChange = onChange
    }

    func start() {
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
            state.debounce {
                onChange()
            }
        }

        source.setCancelHandler {
            close(fd)
        }

        state.setSource(source)
        source.resume()
        logger.info("Watching: \(path)")
    }

    func stop() {
        watcherState.cancel()
        logger.info("Stopped watching")
    }
}

private final class WatcherState: Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var source: DispatchSourceFileSystemObject?
    private nonisolated(unsafe) var debounceWork: DispatchWorkItem?

    func setSource(_ source: DispatchSourceFileSystemObject) {
        lock.lock()
        self.source = source
        lock.unlock()
    }

    func debounce(action: @escaping () -> Void) {
        lock.lock()
        debounceWork?.cancel()
        let work = DispatchWorkItem(block: action)
        debounceWork = work
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + 1.0,
            execute: work
        )
    }

    func cancel() {
        lock.lock()
        debounceWork?.cancel()
        source?.cancel()
        source = nil
        lock.unlock()
    }
}
