import AppKit
import AgenticMenuBarLib

NSApplication.shared.setActivationPolicy(.accessory)
let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
