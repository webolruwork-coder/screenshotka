import AppKit
import CoreImage

/// Холст редактора: базовое изображение + аннотации поверх.
final class EditorView: NSView, NSTextFieldDelegate {
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    var tool: ToolKind = .arrow
    var strokeColor: NSColor = Theme.accent { didSet { editingField?.textColor = strokeColor } }
    var lineWidth: CGFloat = 6

    private let base: CGImage
    private let imageSize: CGSize
    private lazy var baseNSImage = NSImage(cgImage: base, size: imageSize)
    private lazy var pixelatedImage: NSImage = makePixelated()

    private var annotations: [Annotation] = []
    private var redoStack: [Annotation] = []
    private var current: Annotation?

    // Геометрия отрисовки.
    private var drawScale: CGFloat = 1
    private var drawOrigin: CGPoint = .zero

    // Инлайновый ввод текста.
    private var editingField: NSTextField?
    private var editingPointImage: CGPoint = .zero

    var onChange: (() -> Void)?
    // Хоткеи редактора (у меню-бар приложения нет меню File/Edit).
    var onClose: (() -> Void)?
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onDone: (() -> Void)?

    init(image: CGImage) {
        self.base = image
        self.imageSize = CGSize(width: image.width, height: image.height)
        super.init(frame: NSRect(origin: .zero, size: imageSize))
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    // MARK: - Layout

    private var didInitLayout = false
    private var minScale: CGFloat = 0.05
    private let maxScale: CGFloat = 16

    /// Вписывание ВПРИТЫК (без полей): по ограничивающей стороне изображение заполняет
    /// окно целиком. Иначе у длинного скролл-скриншота (вписан по ширине) по бокам
    /// оставались тёмные поля фона — при вертикальном скролле картинка «уезжала под фон».
    private func fitScales() -> (w: CGFloat, h: CGFloat) {
        (bounds.width / imageSize.width, bounds.height / imageSize.height)
    }

    private func recomputeLayout() {
        let (fitW, fitH) = fitScales()
        minScale = min(fitW, fitH)        // не мельче, чем «всё изображение в окне»
        guard !didInitLayout else { clampOrigin(); return }
        guard bounds.width > 50, bounds.height > 50 else { return }   // ждём реальный размер
        // Высокий «скролл-скриншот» (аспект выше окна) — вписываем по ШИРИНЕ и листаем
        // вертикально; обычный снимок — вписываем целиком.
        let imgAspect = imageSize.height / imageSize.width
        let viewAspect = bounds.height / max(1, bounds.width)
        drawScale = (imgAspect > viewAspect) ? fitW : min(fitW, fitH)
        let dw = imageSize.width * drawScale, dh = imageSize.height * drawScale
        drawOrigin = CGPoint(x: (bounds.width - dw) / 2,
                             y: dh <= bounds.height ? (bounds.height - dh) / 2 : 0)   // длинный скриншот открываем сверху
        didInitLayout = true
        clampOrigin()
    }

    /// Держим изображение в разумных пределах: меньше окна — по центру, больше — без «улёта» за край.
    private func clampOrigin() {
        let dw = imageSize.width * drawScale, dh = imageSize.height * drawScale
        // Допуск 0.5pt: при вписывании впритык dw/dh из-за округления могут быть на доли
        // пикселя больше bounds → иначе разрешался бы микро-пан с полоской фона.
        if dw <= bounds.width + 0.5 { drawOrigin.x = (bounds.width - dw) / 2 }
        else { drawOrigin.x = min(0, max(bounds.width - dw, drawOrigin.x)) }
        if dh <= bounds.height + 0.5 { drawOrigin.y = (bounds.height - dh) / 2 }
        else { drawOrigin.y = min(0, max(bounds.height - dh, drawOrigin.y)) }
    }

    override func layout() { super.layout(); recomputeLayout() }

    private func toImage(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - drawOrigin.x) / drawScale, y: (p.y - drawOrigin.y) / drawScale)
    }

    // MARK: - Zoom & scroll

    override func scrollWheel(with event: NSEvent) {
        guard didInitLayout else { return }
        commitTextEditing()   // поле ввода привязано к view-координатам — фиксируем текст до сдвига холста
        drawOrigin.x += event.scrollingDeltaX
        drawOrigin.y += event.scrollingDeltaY
        clampOrigin()
        needsDisplay = true
    }

    override func magnify(with event: NSEvent) {
        commitTextEditing()   // см. scrollWheel
        zoom(by: 1 + event.magnification, around: convert(event.locationInWindow, from: nil))
    }

    /// Зум вокруг точки (курсора), сохраняя её положение на изображении.
    func zoom(by factor: CGFloat, around viewPoint: CGPoint) {
        let newScale = max(minScale, min(maxScale, drawScale * factor))
        guard newScale != drawScale else { return }
        let imgPt = toImage(viewPoint)
        drawScale = newScale
        drawOrigin = CGPoint(x: viewPoint.x - imgPt.x * drawScale,
                             y: viewPoint.y - imgPt.y * drawScale)
        clampOrigin()
        needsDisplay = true
    }

    /// Сбросить к вписыванию (⌘0).
    func resetZoom() {
        didInitLayout = false
        recomputeLayout()
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.10, alpha: 1).setFill()
        bounds.fill()

        NSGraphicsContext.saveGraphicsState()
        let t = NSAffineTransform()
        t.translateX(by: drawOrigin.x, yBy: drawOrigin.y)
        t.scaleX(by: drawScale, yBy: drawScale)
        t.concat()

        baseNSImage.draw(in: CGRect(origin: .zero, size: imageSize))
        for a in annotations { a.draw(pixelated: pixelatedImage) }
        current?.draw(pixelated: pixelatedImage)

        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        commitTextEditing()
        let p = toImage(convert(event.locationInWindow, from: nil))

        if tool == .text {
            beginTextEditing(atImagePoint: p)
            return
        }
        let a = Annotation(kind: tool, color: strokeColor, lineWidth: lineWidth)
        a.start = p; a.end = p
        if tool == .pen { a.points = [p] }
        current = a
    }

    override func mouseDragged(with event: NSEvent) {
        guard let a = current else { return }
        let raw = toImage(convert(event.locationInWindow, from: nil))
        let shift = event.modifierFlags.contains(.shift)
        a.end = constrain(start: a.start, point: raw, kind: a.kind, shift: shift)
        if a.kind == .pen { a.points.append(raw) }
        needsDisplay = true
    }

    /// Shift: линия/стрелка — углы кратно 45°; прямоугольник/овал/маркер/блюр — квадрат.
    private func constrain(start: CGPoint, point p: CGPoint, kind: ToolKind, shift: Bool) -> CGPoint {
        guard shift else { return p }
        let dx = p.x - start.x, dy = p.y - start.y
        switch kind {
        case .line, .arrow:
            let step = CGFloat.pi / 4
            let snapped = (atan2(dy, dx) / step).rounded() * step
            let len = hypot(dx, dy)
            return CGPoint(x: start.x + cos(snapped) * len, y: start.y + sin(snapped) * len)
        case .rect, .ellipse, .highlight, .blur:
            let side = max(abs(dx), abs(dy))
            return CGPoint(x: start.x + (dx < 0 ? -side : side),
                           y: start.y + (dy < 0 ? -side : side))
        case .pen, .text:
            return p
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let a = current else { return }
        current = nil
        // Отбрасываем «пустые» фигуры.
        let dist = hypot(a.end.x - a.start.x, a.end.y - a.start.y)
        if a.kind != .pen && dist < 3 { needsDisplay = true; return }
        annotations.append(a)
        redoStack.removeAll()
        needsDisplay = true
        onChange?()
    }

    // MARK: - Text editing

    private func beginTextEditing(atImagePoint p: CGPoint) {
        editingPointImage = p
        let viewPoint = CGPoint(x: drawOrigin.x + p.x * drawScale, y: drawOrigin.y + p.y * drawScale)
        let fontSize: CGFloat = 28
        let field = NSTextField(frame: NSRect(x: viewPoint.x, y: viewPoint.y, width: 220, height: fontSize * drawScale + 8))
        field.font = NSFont.boldSystemFont(ofSize: fontSize * drawScale)
        field.textColor = strokeColor
        field.backgroundColor = NSColor(white: 0, alpha: 0.25)
        field.isBordered = false
        field.focusRingType = .none
        field.placeholderString = NSLocalizedString("Текст…", comment: "")
        field.delegate = self
        addSubview(field)
        window?.makeFirstResponder(field)
        editingField = field
    }

    private func commitTextEditing() {
        guard let field = editingField else { return }
        let str = field.stringValue
        editingField = nil
        field.removeFromSuperview()
        guard !str.isEmpty else { return }
        let a = Annotation(kind: .text, color: strokeColor, lineWidth: lineWidth)
        a.text = str
        a.fontSize = 28
        a.start = editingPointImage
        annotations.append(a)
        redoStack.removeAll()
        needsDisplay = true
        onChange?()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            commitTextEditing()
            return true
        }
        return false
    }

    // MARK: - Keyboard

    /// ⌘Z — отмена, ⌘⇧Z / ⌘Y — повтор. У меню-бар приложения нет меню Edit,
    /// поэтому ловим хоткеи прямо во вью (через цепочку performKeyEquivalent окна).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        // Во время ввода текста — отдаём системной отмене/копированию поля.
        if editingField != nil { return super.performKeyEquivalent(with: event) }
        let key = event.charactersIgnoringModifiers?.lowercased()
        switch key {
        case "z":
            if event.modifierFlags.contains(.shift) { redo() } else { undo() }
            return true
        case "y":
            redo(); return true
        case "w":
            onClose?(); return true
        case "c":
            onCopy?(); return true
        case "s":
            onSave?(); return true
        case "\r", "\u{3}": // ⌘Enter / ⌘Return — «Готово»
            onDone?(); return true
        case "=", "+":      // ⌘+ — приблизить
            zoom(by: 1.25, around: CGPoint(x: bounds.midX, y: bounds.midY)); return true
        case "-", "_":      // ⌘− — отдалить
            zoom(by: 0.8, around: CGPoint(x: bounds.midX, y: bounds.midY)); return true
        case "0":           // ⌘0 — вписать в окно
            resetZoom(); return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    // MARK: - Commands

    func undo() {
        commitTextEditing()
        guard let last = annotations.popLast() else { return }
        redoStack.append(last)
        needsDisplay = true
        onChange?()
    }
    func redo() {
        guard let a = redoStack.popLast() else { return }
        annotations.append(a)
        needsDisplay = true
        onChange?()
    }
    func clearAll() {
        commitTextEditing()
        redoStack.append(contentsOf: annotations.reversed())
        annotations.removeAll()
        needsDisplay = true
        onChange?()
    }

    // MARK: - Export

    /// Экспорт в нативном разрешении (1:1). Рендер идёт через flipped-вид,
    /// поэтому база, текст, вектор и размытие совпадают с тем, что видно на экране.
    func render() -> CGImage {
        commitTextEditing()
        let exporter = ExportCanvas(base: baseNSImage, pixelated: pixelatedImage,
                                    annotations: annotations, size: imageSize)
        let w = Int(imageSize.width.rounded()), h = Int(imageSize.height.rounded())
        guard w > 0, h > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return base }
        rep.size = imageSize
        exporter.cacheDisplay(in: exporter.bounds, to: rep)
        return rep.cgImage ?? base
    }

    // MARK: - Helpers

    private func makePixelated() -> NSImage {
        let ci = CIImage(cgImage: base)
        let filter = CIFilter(name: "CIPixellate")!
        filter.setValue(ci, forKey: kCIInputImageKey)
        filter.setValue(max(8, max(imageSize.width, imageSize.height) / 50), forKey: kCIInputScaleKey)
        guard let output = filter.outputImage else { return baseNSImage }
        guard let cg = Self.ciContext.createCGImage(output, from: ci.extent) else { return baseNSImage }
        return NSImage(cgImage: cg, size: imageSize)
    }
}

/// Невидимый flipped-холст для экспорта 1:1: рисует то же, что и редактор, но без вписывания.
private final class ExportCanvas: NSView {
    private let base: NSImage
    private let pixelated: NSImage
    private let annotations: [Annotation]

    init(base: NSImage, pixelated: NSImage, annotations: [Annotation], size: CGSize) {
        self.base = base
        self.pixelated = pixelated
        self.annotations = annotations
        super.init(frame: NSRect(origin: .zero, size: size))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        base.draw(in: bounds)
        for a in annotations { a.draw(pixelated: pixelated) }
    }
}
