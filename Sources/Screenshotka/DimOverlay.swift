import AppKit

/// Затемняющий оверлей вокруг записываемой области: тёмная заливка по всем экранам
/// с прозрачной «дырой» под областью записи. Окна принадлежат приложению и потому
/// автоматически исключаются из захвата (как панель управления) — в видео не попадают,
/// служат лишь визуальной рамкой для пользователя.
final class DimOverlay {
    private var windows: [NSWindow] = []

    /// hole — записываемая область в глобальных координатах Cocoa.
    init(hole: CGRect) {
        for screen in NSScreen.screens {
            windows.append(makeWindow(for: screen, hole: hole))
        }
    }

    private func makeWindow(for screen: NSScreen, hole: CGRect) -> NSWindow {
        let frame = screen.frame
        let win = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.isOpaque = false
        win.backgroundColor = .clear
        win.ignoresMouseEvents = true           // сквозной — не мешает работать под затемнением
        win.hasShadow = false
        // Ниже панели управления (.statusBar) и пузыря камеры, но выше обычных окон.
        win.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let view = DimView(frame: NSRect(origin: .zero, size: frame.size))
        // hole в координатах окна (origin окна = origin экрана).
        let local = CGRect(x: hole.minX - frame.minX, y: hole.minY - frame.minY,
                           width: hole.width, height: hole.height)
        view.hole = local.intersection(view.bounds)
        win.contentView = view
        win.orderFrontRegardless()
        return win
    }

    func close() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }
}

private final class DimView: NSView {
    var hole: CGRect = .null { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0, alpha: 0.42).setFill()
        bounds.fill()
        guard !hole.isNull, !hole.isEmpty else { return }
        // Вырезаем прозрачную область поверх затемнения.
        NSColor.clear.setFill()
        hole.fill(using: .copy)
        // Тонкая рамка вокруг записываемой области.
        NSColor(white: 1, alpha: 0.5).setStroke()
        let border = NSBezierPath(rect: hole.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()
    }
}
