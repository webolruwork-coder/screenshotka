import AppKit

/// Окно редактора с минималистичным тулбаром.
final class EditorWindowController: NSWindowController {

    private let editor: EditorView
    private let cgImage: CGImage
    private let captureScale: CGFloat   // backingScaleFactor экрана-источника (для экспорта)
    private var toolButtons: [ToolKind: HoverButton] = [:]
    private var widthButtons: [HoverButton] = []
    private var colorWell: HoverButton?
    private var colorPopover: NSPopover?
    var onClose: (() -> Void)?

    private let palette: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen, .systemTeal, .systemBlue,
        .systemPurple, .systemPink, .systemBrown, .white, .systemGray, .black,
    ]
    private let widths: [(String, CGFloat)] = [("•", 3), ("●", 6), ("⬤", 12)]

    init(image: CGImage, scale: CGFloat = 2) {
        self.cgImage = image
        self.captureScale = scale
        self.editor = EditorView(image: image)

        // Размер окна под изображение, но не больше экрана.
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let maxW = screen.width * 0.9, maxH = screen.height * 0.9 - 60
        let ar = CGFloat(image.width) / CGFloat(image.height)
        var w = min(CGFloat(image.width), maxW)
        var h = w / ar
        if h > maxH { h = maxH; w = h * ar }
        let toolbarH: CGFloat = 52
        let contentRect = NSRect(x: 0, y: 0, width: max(560, w), height: h + toolbarH)

        let window = NSWindow(contentRect: contentRect,
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = NSLocalizedString("Редактор", comment: "")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.backgroundColor = NSColor(white: 0.10, alpha: 1)
        window.center()
        super.init(window: window)

        buildLayout(toolbarHeight: toolbarH)
        // Восстанавливаем прошлый выбор (по умолчанию — прямоугольник / красный / средняя толщина).
        selectTool(Settings.shared.lastTool)
        selectColor(Settings.shared.lastColor)
        selectWidth(Settings.shared.lastWidthIndex)
        // Хоткеи: ⌘W — закрыть, ⌘C — копировать, ⌘S — сохранить, ⌘↩ — готово.
        editor.onClose = { [weak self] in self?.window?.performClose(nil) }
        editor.onCopy = { [weak self] in self?.copy() }
        editor.onSave = { [weak self] in self?.save() }
        editor.onDone = { [weak self] in self?.done() }
        window.delegate = self
    }
    required init?(coder: NSCoder) { fatalError() }

    private func buildLayout(toolbarHeight: CGFloat) {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true

        let toolbar = NSVisualEffectView()
        toolbar.material = .titlebar
        toolbar.blendingMode = .withinWindow
        toolbar.state = .active
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(toolbar)

        editor.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(editor)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: content.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: toolbarHeight),

            editor.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            editor.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            editor.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        // Левая группа: инструменты.
        let tools = NSStackView()
        tools.spacing = 2
        for kind in ToolKind.allCases {
            let b = iconButton(symbol: kind.symbol, tooltip: kind.tooltip) { [weak self] in self?.selectTool(kind) }
            toolButtons[kind] = b
            tools.addArrangedSubview(b)
        }

        // Цвет — один велл, по клику открывается пикер (пресеты + свой цвет).
        let well = colorWellButton()
        colorWell = well

        // Толщина — кружок «circle.fill» разного размера.
        let widthsStack = NSStackView(); widthsStack.spacing = 2
        let widthPts: [CGFloat] = [7, 11, 15]
        for (i, _) in widths.enumerated() {
            let b = iconButton(symbol: "circle.fill", tooltip: NSLocalizedString("Толщина", comment: ""), pointSize: widthPts[i]) { [weak self] in self?.selectWidth(i) }
            widthButtons.append(b)
            widthsStack.addArrangedSubview(b)
        }

        // Действия.
        let undoB = iconButton(symbol: "arrow.uturn.backward", tooltip: NSLocalizedString("Отменить", comment: "")) { [weak self] in self?.editor.undo() }
        let redoB = iconButton(symbol: "arrow.uturn.forward", tooltip: NSLocalizedString("Повторить", comment: "")) { [weak self] in self?.editor.redo() }
        let clearB = iconButton(symbol: "trash", tooltip: NSLocalizedString("Очистить", comment: "")) { [weak self] in self?.editor.clearAll() }

        let copyB = iconButton(symbol: "doc.on.doc", tooltip: NSLocalizedString("Копировать", comment: "")) { [weak self] in self?.copy() }
        let saveB = iconButton(symbol: "tray.and.arrow.down", tooltip: NSLocalizedString("Сохранить", comment: "")) { [weak self] in self?.save() }
        // «Готово» — контурная иконка в том же стиле, что copy/save (без акцентной заливки).
        let doneB = iconButton(symbol: "checkmark.circle", tooltip: NSLocalizedString("Готово", comment: "")) { [weak self] in self?.done() }

        // Верхний тулбар — только инструменты (слева, после «светофора»).
        let leftGroups = NSStackView(views: [tools, separator(), well, widthsStack, separator(), undoB, redoB, clearB])
        leftGroups.spacing = 8
        leftGroups.alignment = .centerY
        leftGroups.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(leftGroups)
        NSLayoutConstraint.activate([
            leftGroups.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 78), // место под «светофор»
            leftGroups.trailingAnchor.constraint(lessThanOrEqualTo: toolbar.trailingAnchor, constant: -12),
            leftGroups.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
        ])

        // Действия (копировать / сохранить / готово) — плавающая плашка снизу-справа над холстом.
        let rightGroups = NSStackView(views: [copyB, saveB, doneB])
        rightGroups.spacing = 8
        rightGroups.alignment = .centerY
        rightGroups.translatesAutoresizingMaskIntoConstraints = false

        let actionBar = NSVisualEffectView()
        actionBar.material = .hudWindow
        actionBar.blendingMode = .withinWindow
        actionBar.state = .active
        actionBar.wantsLayer = true
        actionBar.layer?.cornerRadius = 12
        actionBar.layer?.cornerCurve = .continuous
        actionBar.layer?.masksToBounds = true
        actionBar.layer?.borderWidth = 1
        actionBar.layer?.borderColor = NSColor(white: 1, alpha: 0.08).cgColor
        actionBar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(actionBar, positioned: .above, relativeTo: editor)
        actionBar.addSubview(rightGroups)
        NSLayoutConstraint.activate([
            rightGroups.leadingAnchor.constraint(equalTo: actionBar.leadingAnchor, constant: 8),
            rightGroups.trailingAnchor.constraint(equalTo: actionBar.trailingAnchor, constant: -8),
            rightGroups.topAnchor.constraint(equalTo: actionBar.topAnchor, constant: 6),
            rightGroups.bottomAnchor.constraint(equalTo: actionBar.bottomAnchor, constant: -6),
            actionBar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            actionBar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
    }

    // MARK: - Controls factory

    private func iconButton(symbol: String, tooltip: String, pointSize: CGFloat = 15, action: @escaping () -> Void) -> HoverButton {
        let b = HoverButton(title: "", target: nil, action: nil)
        b.isBordered = false
        // Единый конфиг: одинаковый оптический вес/масштаб у всех глифов — ряд читается «собранным».
        let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular).applying(.init(scale: .medium))
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
            ?? NSImage(systemSymbolName: "questionmark", accessibilityDescription: tooltip)  // фолбэк, чтобы кнопка не была пустой
        b.image = img?.withSymbolConfiguration(cfg)
        b.imagePosition = .imageOnly
        b.contentTintColor = Theme.textPrimary
        b.toolTip = tooltip
        b.setAccessibilityLabel(tooltip)
        b.wantsLayer = true
        b.layer?.cornerRadius = Theme.Radius.sm
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 30).isActive = true
        b.heightAnchor.constraint(equalToConstant: 30).isActive = true
        b.onAction = action
        return b
    }

    private func colorWellButton() -> HoverButton {
        let b = HoverButton(title: "", target: nil, action: nil)
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = 9
        b.layer?.borderWidth = 1.5
        b.layer?.borderColor = NSColor(white: 1, alpha: 0.55).cgColor   // тонкое кольцо, не «жирная» обводка
        b.layer?.backgroundColor = editor.strokeColor.cgColor
        b.hoverScale = 1.12   // лёгкое увеличение на наведении
        b.toolTip = NSLocalizedString("Цвет", comment: "")
        b.setAccessibilityLabel(NSLocalizedString("Цвет", comment: ""))
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 18).isActive = true
        b.heightAnchor.constraint(equalToConstant: 18).isActive = true
        b.onAction = { [weak self] in self?.showColorPopover() }
        return b
    }

    private func showColorPopover() {
        guard let well = colorWell else { return }
        let picker = ColorPickerController(current: editor.strokeColor, presets: palette)
        picker.onPick = { [weak self] color in self?.selectColor(color) }
        let pop = NSPopover()
        pop.contentViewController = picker
        pop.behavior = .transient
        colorPopover = pop
        pop.show(relativeTo: well.bounds, of: well, preferredEdge: .maxY)
    }

    private func separator() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(white: 1, alpha: 0.09).cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        v.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return v
    }

    // MARK: - Selection state

    private func selectTool(_ kind: ToolKind) {
        editor.tool = kind
        Settings.shared.lastTool = kind
        for (k, b) in toolButtons {
            b.layer?.backgroundColor = (k == kind) ? Theme.selectedFill.cgColor : NSColor.clear.cgColor
            b.restingTint = (k == kind) ? Theme.accent : Theme.textPrimary
            b.setAccessibilityValue(k == kind ? NSLocalizedString("выбрано", comment: "") : nil)
        }
    }
    private func selectColor(_ color: NSColor) {
        editor.strokeColor = color
        Settings.shared.lastColor = color
        colorWell?.layer?.backgroundColor = color.cgColor
    }
    private func selectWidth(_ index: Int) {
        editor.lineWidth = widths[index].1
        Settings.shared.lastWidthIndex = index
        // Толщина — всегда монохромна (никогда accent), чтобы не путалась с color-well.
        // Активная: яркая точка + нейтральная подложка. Неактивные: приглушённые.
        for (i, b) in widthButtons.enumerated() {
            b.layer?.backgroundColor = (i == index) ? NSColor(white: 1, alpha: 0.13).cgColor : NSColor.clear.cgColor
            b.restingTint = (i == index) ? Theme.textPrimary : Theme.textSecondary
            b.contentTintColor = b.restingTint
        }
    }

    // MARK: - Actions

    private func copy() {
        ImageStore.copyToClipboard(editor.render())
        close()   // windowWillClose → onClose
    }
    private func save() {
        ImageStore.saveWithDialog(editor.render(), scale: captureScale, in: window) { [weak self] saved in
            if saved { self?.close() }   // закрываем только после успешного сохранения
        }
    }
    private func done() {
        if Settings.shared.copyToClipboard { ImageStore.copyToClipboard(editor.render()) }
        close()
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

extension EditorWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) { onClose?() }
}
