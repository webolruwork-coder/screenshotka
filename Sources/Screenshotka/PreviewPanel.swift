import AppKit

/// Плавающая превьюшка после снимка: размер = мини-картинке, без лишней обвязки.
/// Кнопки — кружками по углам, появляются только при наведении с лёгкой анимацией
/// (как в CleanShot X). Перетаскивается, помнит позицию, работает на нескольких мониторах.
final class PreviewPanel: NSPanel {
    var onAnnotate: (() -> Void)?
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onClose: (() -> Void)?

    private let image: CGImage
    private var dragURL: URL?
    private let videoDuration: Double?
    private var dismissTimer: Timer?
    private let thumbView: DraggableImageView
    private let controls = PassthroughView()
    private let infoBar = NSView()
    private var pinButton: HoverButton?
    private var copyPill: HoverButton?
    private var trackingMoves = false
    private var pinned = false
    private var hovering = false

    private static let btn: CGFloat = 26
    private static let margin: CGFloat = 8
    /// Фиксированный размер плашки (как в CleanShot) — не зависит от пропорций снимка.
    private static let fixedSize = NSSize(width: 224, height: 148)

    init(image: CGImage, initiallyPinned: Bool = false, dragURL: URL? = nil, videoDuration: Double? = nil) {
        self.image = image
        self.dragURL = dragURL
        self.videoDuration = videoDuration
        self.pinned = initiallyPinned
        thumbView = DraggableImageView(image: ImageStore.nsImage(from: image))

        let thumb = PreviewPanel.fixedSize
        super.init(contentRect: NSRect(origin: .zero, size: thumb),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)

        isFloatingPanel = true
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        // НЕ двигаем окно фоном: иначе система перехватывает drag и thumbView не получает
        // mouseDragged → drag-out скриншота не стартует. Перемещение делаем вручную (⌥-drag).
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        delegate = self

        buildUI(thumb: thumb)
        present(size: thumb)
        if initiallyPinned {
            revealControls(true)
            pinButton?.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: NSLocalizedString("Закрепить", comment: ""))?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
            pinButton?.restingTint = Theme.accent
            pinButton?.restingBackground = NSColor.white.withAlphaComponent(0.95).cgColor
        } else {
            scheduleDismiss()
        }
    }

    deinit {
        dismissTimer?.invalidate()
    }

    override var canBecomeKey: Bool { true }

    // ⌘W из главного меню (performClose:) на безрамочной плашке иначе «бибикает».
    override func performClose(_ sender: Any?) {
        if let onClose { onClose() } else { dismissAnimated() }
    }

    // MARK: - UI

    private func buildUI(thumb: NSSize) {
        let W = thumb.width, H = thumb.height

        let card = HoverView(frame: NSRect(origin: .zero, size: thumb))
        card.wantsLayer = true
        card.layer?.cornerRadius = Theme.Radius.lg
        card.layer?.cornerCurve = .continuous
        card.layer?.masksToBounds = true
        card.layer?.backgroundColor = Theme.surface.cgColor
        card.layer?.borderWidth = 1
        card.layer?.borderColor = Theme.surfaceStroke.cgColor
        card.autoresizingMask = [.width, .height]
        card.onHoverChange = { [weak self] in self?.setHovering($0) }

        // Картинка во всю карточку.
        thumbView.frame = card.bounds.insetBy(dx: 1, dy: 1)
        thumbView.imageScaling = .scaleProportionallyUpOrDown
        thumbView.wantsLayer = true
        thumbView.layer?.cornerRadius = Theme.Radius.lg - 1
        thumbView.layer?.cornerCurve = .continuous
        thumbView.layer?.masksToBounds = true
        thumbView.autoresizingMask = [.width, .height]
        thumbView.onClick = { [weak self] in self?.onAnnotate?() }
        thumbView.onMoved = { [weak self] in self?.persistOrigin() }
        thumbView.dragURL = self.dragURL
        if self.dragURL == nil {
            // Файл для drag-and-drop готовим в фоне: PNG-кодирование Retina-кадра
            // занимает сотни мс — в init это фризило UI после каждого снимка.
            Task.detached(priority: .userInitiated) { [weak self, image] in
                let url = ImageStore.dragFile(for: image)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.dragURL = url
                    self.thumbView.dragURL = url
                }
            }
        }
        thumbView.onDragBegan = { [weak self] in self?.dismissTimer?.invalidate() }
        thumbView.onDragEnded = { [weak self] in
            guard let self else { return }
            if !self.pinned, !self.hovering { self.scheduleDismiss() }
        }
        thumbView.toolTip = NSLocalizedString("Перетащите — приложить файл · ⌥ перетащите — переместить · клик — редактор", comment: "")
        card.addSubview(thumbView)

        // Инфо-полоска видео (всегда видна, прячется при наведении).
        if videoDuration != nil {
            buildInfoBar(in: card)
        }

        // Слой управления (поверх, прозрачен для кликов в пустых местах).
        controls.frame = card.bounds
        controls.autoresizingMask = [.width, .height]
        controls.wantsLayer = true
        controls.alphaValue = 0

        let scrim = NSView(frame: controls.bounds)
        scrim.wantsLayer = true
        scrim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.30).cgColor
        scrim.layer?.cornerRadius = Theme.Radius.lg
        scrim.layer?.cornerCurve = .continuous
        scrim.autoresizingMask = [.width, .height]
        controls.addSubview(scrim)

        let m = Self.margin, s = Self.btn
        let close = circleButton("xmark", NSLocalizedString("Закрыть", comment: "")) { [weak self] in self?.onClose?() }
        close.setFrameOrigin(NSPoint(x: m, y: H - m - s))                 // верх-лево
        let pin = circleButton("pin", NSLocalizedString("Закрепить", comment: "")) { [weak self] in self?.togglePin() }
        pin.setFrameOrigin(NSPoint(x: W - m - s, y: H - m - s))           // верх-право
        pinButton = pin
        // Видео → ножницы (обрезка), скриншот → square.and.pencil (аннотации).
        let editSymbol = (videoDuration != nil) ? "scissors" : "square.and.pencil"
        let edit = circleButton(editSymbol, NSLocalizedString("Редактировать", comment: "")) { [weak self] in self?.onAnnotate?() }
        edit.setFrameOrigin(NSPoint(x: m, y: m))                          // низ-лево
        let save = circleButton("square.and.arrow.down", NSLocalizedString("Сохранить", comment: "")) { [weak self] in self?.onSave?() }
        save.setFrameOrigin(NSPoint(x: W - m - s, y: m))                  // низ-право
        [close, pin, edit, save].forEach { controls.addSubview($0) }

        let copy = pill(NSLocalizedString("Копировать", comment: "")) { }
        copy.onAction = { [weak self, weak copy] in if let copy { self?.copyTapped(copy) } }
        copy.setFrameOrigin(NSPoint(x: (W - copy.frame.width) / 2, y: (H - copy.frame.height) / 2))
        controls.addSubview(copy)
        copyPill = copy

        card.addSubview(controls)
        contentView = card
    }

    private func circleButton(_ symbol: String, _ tip: String, action: @escaping () -> Void) -> HoverButton {
        let b = HoverButton(title: "", target: nil, action: nil)
        b.isBordered = false
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        b.imagePosition = .imageOnly
        b.setFrameSize(NSSize(width: Self.btn, height: Self.btn))
        b.wantsLayer = true
        b.layer?.cornerRadius = Self.btn / 2
        b.layer?.masksToBounds = true
        b.restingTint = .white
        b.hoverTint = .white
        b.restingBackground = NSColor.black.withAlphaComponent(0.5).cgColor
        b.hoverBackground = Theme.accent.cgColor
        b.toolTip = tip
        b.setAccessibilityLabel(tip)
        b.onAction = action
        return b
    }

    /// Нижняя полоска для видео: иконка + длительность слева, размер файла справа.
    /// Видна всегда, кроме наведения (тогда её перекрывает слой управления).
    private func buildInfoBar(in card: NSView) {
        let H: CGFloat = 30
        infoBar.frame = NSRect(x: 0, y: 0, width: card.bounds.width, height: H)
        infoBar.autoresizingMask = [.width]
        infoBar.wantsLayer = true

        // Тёмный градиент снизу — чтобы текст читался поверх кадра.
        let grad = CAGradientLayer()
        grad.frame = infoBar.bounds
        grad.colors = [NSColor.black.withAlphaComponent(0.55).cgColor, NSColor.clear.cgColor]
        grad.startPoint = CGPoint(x: 0.5, y: 0)
        grad.endPoint = CGPoint(x: 0.5, y: 1)
        grad.autoresizingMask = [.layerWidthSizable]
        infoBar.layer?.addSublayer(grad)

        let pad: CGFloat = 9
        // Слева: иконка видео + длительность.
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "video.fill", accessibilityDescription: NSLocalizedString("Видео", comment: ""))?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        icon.contentTintColor = .white
        icon.frame = NSRect(x: pad, y: (H - 14) / 2, width: 18, height: 14)
        infoBar.addSubview(icon)

        let dur = label(durationText(videoDuration ?? 0))
        dur.frame = NSRect(x: pad + 22, y: (H - 16) / 2, width: 80, height: 16)
        infoBar.addSubview(dur)

        // Справа: размер файла.
        let size = label(fileSizeText())
        size.alignment = .right
        size.frame = NSRect(x: card.bounds.width - 120 - pad, y: (H - 16) / 2, width: 120, height: 16)
        size.autoresizingMask = [.minXMargin]
        infoBar.addSubview(size)

        card.addSubview(infoBar)
    }

    private func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 12, weight: .semibold)
        l.textColor = .white
        l.backgroundColor = .clear
        l.isBezeled = false
        l.isEditable = false
        return l
    }

    private func durationText(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 60 ? String(format: "%d:%02d", s / 60, s % 60) : "\(s)s"
    }

    private func fileSizeText() -> String {
        guard let url = dragURL,
              let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return "" }
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: Int64(bytes))
    }

    private func pill(_ title: String, action: @escaping () -> Void) -> HoverButton {
        let b = HoverButton(title: "", target: nil, action: nil)
        b.isBordered = false
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.black.withAlphaComponent(0.85),
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
        ])
        let w = b.attributedTitle.size().width + 26
        b.setFrameSize(NSSize(width: max(64, w), height: 28))
        b.wantsLayer = true
        b.layer?.cornerRadius = 14
        b.layer?.masksToBounds = true
        b.restingBackground = NSColor(white: 0.95, alpha: 0.95).cgColor
        b.hoverBackground = NSColor(white: 0.78, alpha: 1).cgColor   // заметный ховер (нажатие)
        b.toolTip = title
        b.setAccessibilityLabel(title)
        b.onAction = action
        return b
    }

    /// Превращает плашку в состояние «успех» (зелёная, с галочкой).
    private func applySuccessStyle(to pill: HoverButton) {
        pill.isEnabled = false
        pill.attributedTitle = NSAttributedString(string: "")
        pill.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: NSLocalizedString("Скопировано", comment: ""))?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .bold))
        pill.imagePosition = .imageOnly
        pill.contentTintColor = .white
        pill.hoverBackground = NSColor.systemGreen.cgColor
        pill.restingBackground = NSColor.systemGreen.cgColor   // зелёный успех
        pill.setAccessibilityLabel(NSLocalizedString("Скопировано", comment: ""))
    }

    /// Копирование: успех (зелёная плашка с галочкой) → автоскрытие.
    private func copyTapped(_ pill: HoverButton) {
        dismissTimer?.invalidate()
        onCopy?()
        applySuccessStyle(to: pill)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in self?.onClose?() }
    }

    func showCopiedAndDismiss(_ completion: (() -> Void)? = nil) {
        // Закрытие (кнопкой «закрыть» или по таймеру) уводит плашку с анимацией
        // и вызывает completion (очистку из массива превью).
        onClose = { [weak self] in self?.dismissAnimated(completion) }

        // Ведём себя как обычное превью: кнопки скрыты и появляются только при
        // наведении, плашка остаётся «Копировать» (зелёная — только по нажатию).
        // Автоскрытие через 6 c с паузой при наведении мыши.
        scheduleDismiss()
    }

    // MARK: - Hover / controls reveal

    private func setHovering(_ h: Bool) {
        hovering = h
        revealControls(h)
        if h { dismissTimer?.invalidate() } else if !pinned { scheduleDismiss() }
    }

    private func revealControls(_ show: Bool) {
        // Инфо-полоска видео видна, когда кнопки скрыты, и наоборот.
        if Theme.reduceMotion {
            controls.alphaValue = show ? 1 : 0
            infoBar.alphaValue = show ? 0 : 1
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: show ? .easeOut : .easeIn)
            controls.animator().alphaValue = show ? 1 : 0
            infoBar.animator().alphaValue = show ? 0 : 1
        }
    }

    private func togglePin() {
        pinned.toggle()
        if pinned {
            dismissTimer?.invalidate()
        } else if !hovering {
            scheduleDismiss()
        }
        pinButton?.image = NSImage(systemSymbolName: pinned ? "pin.fill" : "pin", accessibilityDescription: NSLocalizedString("Закрепить", comment: ""))?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        pinButton?.restingTint = pinned ? Theme.accent : .white
        pinButton?.restingBackground = (pinned ? NSColor.white.withAlphaComponent(0.95) : NSColor.black.withAlphaComponent(0.5)).cgColor
    }

    // MARK: - Positioning & persistence

    private func present(size: NSSize) {
        setFrameOrigin(targetOrigin(for: size))
        trackingMoves = true
        alphaValue = 1
        orderFrontRegardless()
    }

    private func targetOrigin(for size: NSSize) -> NSPoint {
        if let saved = Settings.shared.previewOrigin {
            let r = NSRect(origin: saved, size: size)
            if let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(r) }) {
                return clamp(origin: saved, size: size, into: screen.visibleFrame)
            }
        }
        let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        return NSPoint(x: vf.minX + 24, y: vf.minY + 24)
    }

    private func clamp(origin: NSPoint, size: NSSize, into vf: NSRect) -> NSPoint {
        let x = min(max(origin.x, vf.minX), max(vf.minX, vf.maxX - size.width))
        let y = min(max(origin.y, vf.minY), max(vf.minY, vf.maxY - size.height))
        return NSPoint(x: x, y: y)
    }

    fileprivate func persistOrigin() {
        guard trackingMoves else { return }
        Settings.shared.previewOrigin = frame.origin
    }

    // MARK: - Dismiss

    private func scheduleDismiss() {
        guard !pinned else { return }
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 6.0, repeats: false) { [weak self] _ in
            self?.onClose?()
        }
    }

    func dismissAnimated(_ completion: (() -> Void)? = nil) {
        dismissTimer?.invalidate()
        trackingMoves = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Theme.duration(0.16)
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
            completion?()
        })
    }
}

extension PreviewPanel: NSWindowDelegate {
    func windowDidMove(_ notification: Notification) { persistOrigin() }
}

/// Вид с колбэком наведения (для паузы авто-скрытия и показа кнопок).
final class HoverView: NSView {
    var onHoverChange: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }
}

/// Прозрачный для кликов слой управления: ловит только кнопки и только когда видим.
final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard alphaValue > 0.5 else { return nil }
        let v = super.hitTest(point)
        return (v is NSButton) ? v : nil
    }
}

/// Кнопка, реагирующая на наведение, через штатный target/action.
/// По умолчанию меняет только цвет иконки; фон на ховере — опционально.
final class HoverButton: NSButton {
    var onAction: (() -> Void)? {
        didSet { target = self; action = #selector(fire) }
    }
    var restingTint: NSColor = Theme.textPrimary {
        didSet { contentTintColor = restingTint }
    }
    var hoverTint: NSColor = Theme.accent
    var restingBackground: CGColor? {
        didSet { layer?.backgroundColor = restingBackground }
    }
    var hoverBackground: CGColor?
    var hoverScale: CGFloat = 1.0   // >1 — лёгкое увеличение на наведении
    private var tracking: NSTrackingArea?

    @objc private func fire() { onAction?() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        // .cursorUpdate — чтобы менять курсор на «руку» при наведении (как у кликабельных элементов).
        let t = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .cursorUpdate, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }
    /// Курсор-«рука» на наведении для активной кнопки (неактивная — обычная стрелка).
    override func cursorUpdate(with event: NSEvent) {
        if isEnabled { NSCursor.pointingHand.set() } else { super.cursorUpdate(with: event) }
    }
    override func mouseEntered(with event: NSEvent) {
        contentTintColor = hoverTint
        if let h = hoverBackground { layer?.backgroundColor = h }
        if hoverScale != 1.0 { layer?.transform = CATransform3DMakeScale(hoverScale, hoverScale, 1) }
    }
    override func mouseExited(with event: NSEvent) {
        contentTintColor = restingTint
        if hoverBackground != nil { layer?.backgroundColor = restingBackground }
        if hoverScale != 1.0 { layer?.transform = CATransform3DIdentity }
    }
}

/// Превью: клик — редактор; обычный drag — отдать PNG наружу; ⌥ drag — переместить плашку.
final class DraggableImageView: NSImageView, NSDraggingSource {
    // Окно не должно «уезжать» при перетаскивании по картинке — события нужны нам самим.
    override var mouseDownCanMoveWindow: Bool { false }
    var onClick: (() -> Void)?
    var onMoved: (() -> Void)?
    var onDragBegan: (() -> Void)?
    var onDragEnded: (() -> Void)?
    var dragURL: URL?
    private var dragging = false
    private var externalDragging = false
    private var lastMouse: NSPoint = .zero
    private var mouseDownPoint: NSPoint = .zero
    private let dragThreshold: CGFloat = 6
    private var tracking: NSTrackingArea?

    // Курсор-«рука» НЕ через addCursorRect/cursorUpdate: оба механизма работают только
    // на key-окне, а превью — nonactivatingPanel у фонового приложения, key не становится.
    // Поэтому ставим курсор прямо в mouseEntered/mouseExited (они срабатывают при .activeAlways,
    // и пока курсор над нашей панелью — её никто не перебивает, т.к. cursor rects отключены).
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.activeAlways, .mouseEnteredAndExited, .cursorUpdate, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }
    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }

    // Ключевое для drag из фонового приложения: по умолчанию первый клик по не-key окну
    // лишь активирует его, а сам жест (down→drag) проглатывается — поэтому drag наружу не
    // стартовал «с первого раза». true = обрабатываем первый клик полностью, вместе с drag.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        dragging = false
        externalDragging = false
        lastMouse = NSEvent.mouseLocation
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        NSCursor.pointingHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        if externalDragging { return }
        let currentPoint = convert(event.locationInWindow, from: nil)
        let distance = hypot(currentPoint.x - mouseDownPoint.x, currentPoint.y - mouseDownPoint.y)
        guard dragging || distance >= dragThreshold else { return }

        if !event.modifierFlags.contains(.option), let dragURL {
            beginExternalDrag(with: dragURL, event: event)
            return
        }

        dragging = true
        let now = NSEvent.mouseLocation
        if let win = window {
            var o = win.frame.origin
            o.x += now.x - lastMouse.x
            o.y += now.y - lastMouse.y
            win.setFrameOrigin(o)
        }
        lastMouse = now
    }

    override func mouseUp(with event: NSEvent) {
        if dragging { onMoved?() }
        else if !externalDragging { onClick?() }
    }

    private func beginExternalDrag(with url: URL, event: NSEvent) {
        externalDragging = true
        onDragBegan?()

        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let drag = makeDragImage()
        // Кадр строго по размеру миниатюры (без растяжения) и по центру плашки —
        // перетаскивание выглядит естественно, картинка не искажается.
        let frame = NSRect(x: (bounds.width - drag.size.width) / 2,
                           y: (bounds.height - drag.size.height) / 2,
                           width: drag.size.width, height: drag.size.height)
        item.setDraggingFrame(frame, contents: drag)

        // Сессию запускаем ДО анимации «подхвата»: если уменьшить слой-источник
        // раньше, первый drag визуально «не цепляется» (картинка не отрывается от
        // плашки). Сначала отдаём системе чистый кадр — потом косметика.
        beginDraggingSession(with: [item], event: event, source: self)
        setLifted(true)   // лёгкая анимация «подхвата»: плашка чуть уменьшается
    }

    /// Аккуратная картинка для drag: миниатюра с сохранением пропорций, скруглёнными
    /// углами и тонкой рамкой — как сама плашка. Раньше тянулся полноразмерный кадр в
    /// фиксированный прямоугольник плашки → искажение и «глюки».
    private func makeDragImage() -> NSImage {
        guard let src = image, src.size.width > 0, src.size.height > 0 else {
            return image ?? NSWorkspace.shared.icon(forFile: dragURL?.path ?? "/")
        }
        let maxSide: CGFloat = 220
        let s = src.size
        let k = min(maxSide / max(s.width, s.height), 1)
        let sz = NSSize(width: max(1, (s.width * k).rounded()), height: max(1, (s.height * k).rounded()))
        let out = NSImage(size: sz)
        out.lockFocus()
        let rect = NSRect(origin: .zero, size: sz)
        let radius: CGFloat = 8
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
        src.draw(in: rect)
        NSColor(white: 1, alpha: 0.5).setStroke()
        let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        border.lineWidth = 1
        border.stroke()
        out.unlockFocus()
        return out
    }

    /// Анимация «подхвата»: вся плашка плавно уменьшается при старте перетаскивания
    /// и возвращается по завершении — как в CleanShot.
    private func setLifted(_ lifted: Bool) {
        guard let layer = superview?.layer else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(Theme.reduceMotion ? 0 : 0.18)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: lifted ? .easeOut : .easeInEaseOut))
        layer.transform = lifted ? CATransform3DMakeScale(0.9, 0.9, 1) : CATransform3DIdentity
        CATransaction.commit()
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        setLifted(false)   // вернуть плашку к обычному размеру
        onDragEnded?()
        // externalDragging НЕ сбрасываем здесь: система досылает mouseUp уже после
        // завершения drag-сессии, и если флаг сброшен — mouseUp примет это за клик
        // и откроет редактор. Сброс делаем в mouseDown следующего цикла.
    }
}
