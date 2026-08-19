import AppKit

MainActor.assumeIsolated {
    let appDelegate = AppDelegate()
    NSApplication.shared.delegate = appDelegate
    NSApp.setActivationPolicy(.regular)
    withExtendedLifetime(appDelegate) {
        NSApp.run()
    }
}
