import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var window: NSWindow?
    private var mainViewController: TouchLabViewController?
    private var terminationPending = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller = mainViewController else { return .terminateNow }
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        controller.prepareForTermination()
        Task { @MainActor in
            while !(await controller.flushHotCues()) {
                let alert = NSAlert()
                alert.messageText = "핫큐를 저장하지 못했습니다"
                alert.informativeText = "다시 시도하거나 저장하지 않고 종료할 수 있습니다. 저장하지 않은 변경은 사라집니다."
                alert.addButton(withTitle: "다시 시도")
                alert.addButton(withTitle: "저장하지 않고 종료")
                alert.addButton(withTitle: "취소")
                let response = alert.runModal()
                if response == .alertSecondButtonReturn { break }
                if response != .alertFirstButtonReturn {
                    terminationPending = false
                    sender.reply(toApplicationShouldTerminate: false)
                    return
                }
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

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
