import AppKit

/// Обратный отсчёт перед началом записи (3 · 2 · 1).
final class CountdownOverlay {
    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")
    private var value: Int
    private let completion: () -> Void
    private var timer: Timer?

    /// Показывает отсчёт на экране и вызывает completion по завершении.
    static func run(on screen: NSScreen, from: Int, completion: @escaping () -> Void) {
        let o = CountdownOverlay(on: screen, from: from, completion: completion)
        // удерживаем до завершения
        Self.active = o
    }
    private static var active: CountdownOverlay?

    private init(on screen: NSScreen, from: Int, completion: @escaping () -> Void) {
        self.value = from
        self.completion = completion

        let size: CGFloat = 140
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        p.isOpaque = false
        p.backgroundColor = .clear
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let card = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor(white: 0, alpha: 0.72).cgColor
        card.layer?.cornerRadius = 28
        card.layer?.cornerCurve = .continuous

        label.frame = card.bounds
        label.alignment = .center
        label.font = .systemFont(ofSize: 84, weight: .semibold)
        label.textColor = .white
        label.stringValue = "\(from)"
        card.addSubview(label)
        p.contentView = card

        let vf = screen.frame
        p.setFrameOrigin(NSPoint(x: vf.midX - size/2, y: vf.midY - size/2))
        p.orderFrontRegardless()
        self.panel = p

        timer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in self?.tick() }
    }

    deinit {
        timer?.invalidate()
        panel?.orderOut(nil)
    }

    private func tick() {
        value -= 1
        if value <= 0 {
            timer?.invalidate()
            panel?.orderOut(nil)
            panel = nil
            let done = completion
            CountdownOverlay.active = nil
            done()
        } else {
            label.stringValue = "\(value)"
        }
    }
}
