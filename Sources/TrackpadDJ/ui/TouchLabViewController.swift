import AppKit

/// Hosts the TouchLabView and makes it first responder so touch events are delivered.
final class TouchLabViewController: NSViewController {

    private var touchLabView: TouchLabView!

    override func loadView() {
        touchLabView = TouchLabView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        view = touchLabView
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(touchLabView)
    }
}
