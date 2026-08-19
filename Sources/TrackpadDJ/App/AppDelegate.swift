import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var window: NSWindow?
    private var mainViewController: TouchLabViewController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let vc = TouchLabViewController()
        let window = NSWindow(contentViewController: vc)
        window.setContentSize(NSSize(width: 1_180, height: 720))
        window.contentMinSize = NSSize(width: 960, height: 620)
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.title = "Trackpad DJ"
        window.center()
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(
            srgbRed: 0.043,
            green: 0.051,
            blue: 0.063,
            alpha: 1
        )
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
