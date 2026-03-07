import AppKit

// Top-level constant keeps the delegate alive for the lifetime of the app.
let appDelegate = AppDelegate()
NSApplication.shared.delegate = appDelegate
NSApp.setActivationPolicy(.regular)
NSApp.run()
