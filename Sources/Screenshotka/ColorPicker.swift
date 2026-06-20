import AppKit

/// Поповер выбора цвета: сетка пресетов + «Свой цвет…» (системная палитра).
final class ColorPickerController: NSViewController {
    var onPick: ((NSColor) -> Void)?

    private let presets: [NSColor]
    private var current: NSColor
    private var swatches: [ColorSwatch] = []

    init(current: NSColor, presets: [NSColor]) {
        self.current = current
        self.presets = presets
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let cols = 6
        let sw: CGFloat = 22, gap: CGFloat = 10, pad: CGFloat = 14
        let rows = Int(ceil(Double(presets.count) / Double(cols)))
        let gridW = CGFloat(cols) * sw + CGFloat(cols - 1) * gap
        let gridH = CGFloat(rows) * sw + CGFloat(rows - 1) * gap
        let customH: CGFloat = 28
        let width = gridW + pad * 2
        let height = pad + gridH + 12 + customH + pad

        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        // Сетка пресетов (origin внизу-слева → первая строка сверху).
        for (i, color) in presets.enumerated() {
            let r = i / cols, c = i % cols
            let x = pad + CGFloat(c) * (sw + gap)
            let y = height - pad - sw - CGFloat(r) * (sw + gap)
            let b = ColorSwatch(color: color)
            b.frame = NSRect(x: x, y: y, width: sw, height: sw)
            b.selected = color.isClose(to: current)
            b.onPick = { [weak self] in self?.pick(color) }
            root.addSubview(b)
            swatches.append(b)
        }

        // «Свой цвет…»
        let custom = HoverButton(title: "", target: nil, action: nil)
        custom.isBordered = false
        custom.attributedTitle = NSAttributedString(string: NSLocalizedString("Свой цвет…", comment: ""), attributes: [
            .foregroundColor: Theme.textPrimary,
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
        ])
        let icon = NSImage(systemSymbolName: "eyedropper.halffull", accessibilityDescription: NSLocalizedString("Свой цвет", comment: ""))?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .regular))
        custom.image = icon
        custom.imagePosition = .imageLeading
        custom.imageHugsTitle = true
        custom.contentTintColor = Theme.textSecondary
        custom.frame = NSRect(x: pad, y: pad, width: gridW, height: customH)
        custom.wantsLayer = true
        custom.layer?.cornerRadius = Theme.Radius.sm
        custom.restingBackground = NSColor(white: 1, alpha: 0.06).cgColor
        custom.hoverBackground = NSColor(white: 1, alpha: 0.12).cgColor
        custom.onAction = { [weak self] in self?.openSystemPicker() }
        root.addSubview(custom)

        self.view = root
    }

    private func pick(_ color: NSColor) {
        current = color
        swatches.forEach { $0.selected = $0.color.isClose(to: color) }
        onPick?(color)
    }

    /// NSColorPanel держит target БЕЗ retain: если контроллер освободится (поповер
    /// пересоздали), панель будет слать action в висячий указатель → краш. Держим
    /// последнего владельца статически, пока открыта системная палитра.
    private static var colorPanelOwner: AnyObject?

    private func openSystemPicker() {
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = current
        Self.colorPanelOwner = self
        panel.setTarget(self)
        panel.setAction(#selector(systemColorChanged(_:)))
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func systemColorChanged(_ sender: NSColorPanel) {
        current = sender.color
        swatches.forEach { $0.selected = false }
        onPick?(sender.color)
    }
}

/// Кружок-образец цвета.
final class ColorSwatch: NSButton {
    let color: NSColor
    var onPick: (() -> Void)?
    var selected = false { didSet { needsDisplay = true } }

    // Кликабельный образец цвета → курсор-«рука».
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        isBordered = false
        title = ""
        target = self
        action = #selector(fire)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func fire() { onPick?() }

    override func draw(_ dirtyRect: NSRect) {
        let inset: CGFloat = selected ? 3 : 0.5
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: inset, dy: inset))
        color.setFill(); circle.fill()
        // тонкая обводка для светлых цветов
        NSColor(white: 1, alpha: 0.25).setStroke(); circle.lineWidth = 1; circle.stroke()
        if selected {
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5))
            Theme.accent.setStroke(); ring.lineWidth = 2; ring.stroke()
        }
    }
}

extension NSColor {
    /// Грубое сравнение в RGB для подсветки выбранного пресета.
    func isClose(to other: NSColor) -> Bool {
        guard let a = usingColorSpace(.deviceRGB), let b = other.usingColorSpace(.deviceRGB) else { return false }
        let d = abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent)
        return d < 0.02
    }
}
