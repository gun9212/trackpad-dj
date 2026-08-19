import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var window: NSWindow?
    private var mainViewController: TouchLabViewController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let vc = TouchLabViewController()
        let window = NSWindow(contentViewController: vc)
        window.setContentSize(NSSize(width: 900, height: 600))
        window.title = "Trackpad DJ — Single Jog"
        window.center()
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(white: 0.08, alpha: 1.0)
        window.makeKeyAndOrderFront(nil)
        self.window = window
        mainViewController = vc

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        mainViewController?.shutdown()
    }
}
