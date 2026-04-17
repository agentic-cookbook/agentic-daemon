import AppKit
import Foundation
import AgenticXPCProtocol
import DaemonKit

/// Opens a non-modal window showing the full content of a crash report.
/// Retains itself until the window is closed.
@MainActor
public final class CrashDetailWindow: NSObject, NSWindowDelegate {

    private let window: NSWindow

    public static func show(report: CrashReport) {
        // CrashDetailWindow retains itself via the window delegate until closed
        let viewer = CrashDetailWindow(report: report)
        viewer.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(report: CrashReport) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = "Crash Report — \(report.taskName)"
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false

        let scrollView = NSScrollView(frame: window.contentView!.bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true

        let textView = NSTextView(frame: scrollView.contentSize.asRect)
        textView.autoresizingMask = [.width]
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.string = Self.format(report)

        scrollView.documentView = textView
        window.contentView?.addSubview(scrollView)
    }

    public func windowWillClose(_ notification: Notification) {
        // Break the retain cycle so this object is deallocated
        window.delegate = nil
    }

    // MARK: - Formatting

    private static func format(_ report: CrashReport) -> String {
        var lines: [String] = []
        lines.append("Task:            \(report.taskName)")
        lines.append("Timestamp:       \(report.timestamp)")
        lines.append("Source:          \(report.source.rawValue)")
        if let sig = report.signal        { lines.append("Signal:          \(sig)") }
        if let exc = report.exceptionType { lines.append("Exception Type:  \(exc)") }
        if let th  = report.faultingThread { lines.append("Faulting Thread: \(th)") }

        if let frames = report.stackTrace, !frames.isEmpty {
            lines.append("")
            lines.append("Stack Trace:")
            lines.append(String(repeating: "─", count: 60))
            for (i, frame) in frames.enumerated() {
                var line = String(format: "  %3d", i)
                if let sym = frame.symbol      { line += "  \(sym)" }
                if let off = frame.imageOffset { line += " + \(off)" }
                if let file = frame.sourceFile, let ln = frame.sourceLine {
                    line += "  (\(file):\(ln))"
                }
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }
}

private extension CGSize {
    var asRect: CGRect { CGRect(origin: .zero, size: self) }
}
