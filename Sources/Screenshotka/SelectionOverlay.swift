import AppKit

/// Результат работы оверлея выделения.
enum SelectionResult {
    case area(CGRect, NSScreen)         // живой режим: вырезать после закрытия оверлея
    case image(CGImage, CGFloat)        // заморозка: готовый кадр + backingScaleFactor экрана
    case videoArea(CGRect, NSScreen)    // область для записи видео
    case window(CGWindowID)
    case cancelled
}

/// Окно-оверлей: прозрачное, поверх всего, может стать ключевым.
/// Non-activating-панель: становится key и принимает мышь/Esc, НЕ активируя
/// приложение и не переключая Spaces (иначе экран «дёргается» при показе/закрытии).
final class OverlayWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // ⌘W из главного меню (performClose:) на безрамочном оверлее иначе «бибикает» —
    // трактуем как отмену выделения (как Esc).
    override func performClose(_ sender: Any?) {
        (contentView as? SelectionView)?.onResult?(.cancelled)
    }
}

/// Управляет оверлеями на всех экранах.
final class SelectionOverlayController {
    enum Mode { case area, window, video }

    private var windows: [OverlayWindow] = []
    private var views: [SelectionView] = []
    private var completion: ((SelectionResult) -> Void)?
    private var finished = false
    private var windowSubmode = false   // общий «Пробел → окно» для всех мониторов (видео и область)
    private var activationObserver: NSObjectProtocol?

    func present(mode: Mode, frozen: [CGDirectDisplayID: CGImage] = [:],
                 completion: @escaping (SelectionResult) -> Void) {
        self.completion = completion
        self.finished = false
        // Активируем приложение, иначе безрамочный оверлей не получает клавиатуру
        // (Esc/Пробел уходят в активное приложение). Мерцание давала «заморозка» —
        // она отключена, так что активация рывок не возвращает.
        NSApp.activate(ignoringOtherApps: true)

        for screen in NSScreen.screens {
            let window = OverlayWindow(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered, defer: false, screen: screen)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            window.ignoresMouseEvents = false
            window.acceptsMouseMovedEvents = true
            window.hasShadow = false
            window.hidesOnDeactivate = false   // NSPanel по умолчанию прячется при деактивации — не нужно
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

            let viewMode: SelectionView.Mode
            switch mode {
            case .window: viewMode = .window
            case .video: viewMode = .video
            case .area: viewMode = .area
            }
            let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size),
                                     screen: screen, mode: viewMode)
            if let id = screen.displayID { view.frozenImage = frozen[id] }
            view.onResult = { [weak self] result in self?.finish(result) }
            // Пробел ловит только key-оверлей — транслируем подрежим на все экраны,
            // иначе на втором мониторе подсказка/режим не менялись.
            view.onToggleWindowSubmode = { [weak self] in
                guard let self else { return }
                self.windowSubmode.toggle()
                self.views.forEach { $0.setWindowSubmode(self.windowSubmode) }
                // Курсор «мишень ↔ камера» должен смениться сразу по Пробелу, а не после
                // движения мыши (см. forceReticleNow — та же история, что при показе оверлея).
                self.forceReticleNow()
            }
            window.contentView = view
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)   // key без активации приложения (nonactivating-панель)
            view.attachWindow(window)
            windows.append(window)
            views.append(view)
        }
        if mode == .window {
            let infos = ScreenCapturer.onscreenWindows()
            views.forEach { $0.provideWindows(infos) }
        }
        // Прицел должен появиться СРАЗУ под неподвижной мышью. Делаем это и сейчас
        // (если приложение уже активно), и в момент реальной активации, и парой
        // коротких отложенных повторов — чтобы перекрыть гонку с async-активацией.
        forceReticleNow()
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.forceReticleNow()
        }
        for delay in [0.05, 0.15] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.forceReticleNow() }
        }
    }

    /// Заставляет курсор-«мишень» отрисоваться немедленно, не дожидаясь движения мыши.
    ///
    /// `NSCursor.set()` лишь запоминает «текущий курсор» — его картинку window server
    /// перерисовывает только по cursor-update-событию (движение мыши, переоценка
    /// tracking area). Оверлей же возникает под НЕПОДВИЖНЫМ курсором, да и
    /// `NSApp.activate()` асинхронна, поэтому раньше прицел всплывал лишь после
    /// первого движения, причём непредсказуемо.
    ///
    /// Ставим курсор режима на всех вью и «толкаем» мышь в ЕЁ ЖЕ текущую позицию:
    /// сдвиг нулевой (визуально незаметно), но система шлёт cursor-update и прицел
    /// рисуется сразу. Поскольку варп всегда в текущую точку, повторные/отложенные
    /// вызовы никогда не дёргают курсор — в т.ч. если выделение уже началось.
    /// `CGWarpMouseCursorPosition` не требует TCC-разрешений (в отличие от
    /// синтетических CGEvent), а `CGAssociateMouseAndMouseCursorPosition(true)`
    /// снимает кратковременную «заморозку» движения после варпа.
    private func forceReticleNow() {
        guard !finished, !windows.isEmpty else { return }
        views.forEach { $0.refreshCursor() }
        guard let primary = NSScreen.screens.first else { return }
        let loc = NSEvent.mouseLocation                      // Cocoa: origin внизу-слева
        CGWarpMouseCursorPosition(CGPoint(x: loc.x, y: primary.frame.maxY - loc.y))
        CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
    }

    private func finish(_ result: SelectionResult) {
        guard !finished else { return }
        finished = true
        let handler = completion
        completion = nil
        // Мгновенное закрытие без анимации: fade-out полноэкранного (затемнённого)
        // оверлея читается как «мерцание/дёрганье» всего экрана после снимка.
        dismiss()
        handler?(result)
    }

    func dismiss() {
        // Гасим все источники «мишени» ДО закрытия окон (tracking area с .cursorUpdate),
        // затем закрываем окна и НАДЁЖНО сбрасываем курсор: иначе прицел иногда «залипал»
        // до клика/движения мыши (window server не переоценивал курсор без движения).
        if let o = activationObserver { NotificationCenter.default.removeObserver(o); activationObserver = nil }
        views.forEach { $0.teardown() }
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        views.removeAll()
        Self.resetCursorToArrow()
    }

    /// Возврат стрелки сразу + несколько отложенных повторов: перекрывает гонку с
    /// отложенными cursorUpdate-событиями и задержкой переоценки курсора системой.
    static func resetCursorToArrow() {
        NSCursor.arrow.set()
        for delay in [0.02, 0.08, 0.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { NSCursor.arrow.set() }
        }
    }
}

/// Вид выделения области: затемнение, аккуратная белая рамка с уголками, плашка размера.
/// Снимок делается по отпусканию кнопки мыши/трекпада (как в CleanShot X).
final class SelectionView: NSView {
    enum Mode { case area, window, video }

    var onResult: ((SelectionResult) -> Void)?
    var frozenImage: CGImage? {   // заморозка экрана (если включена)
        didSet {
            frozenNSImage = frozenImage.map { NSImage(cgImage: $0, size: bounds.size) }
        }
    }

    private let screenRef: NSScreen
    private let mode: Mode
    /// Оверлей закрывается: все установщики курсора-«мишени» должны замолчать,
    /// иначе отложенный cursorUpdate вернёт прицел после сброса на стрелку.
    private var dismissed = false

    /// Переустановить курсор режима (вызывается при реальной активации приложения).
    func refreshCursor() {
        if !dismissed { activeCursor.set() }
    }

    func teardown() {
        dismissed = true
        trackingAreas.forEach(removeTrackingArea)
        window?.invalidateCursorRects(for: self)
    }

    private func complete(_ result: SelectionResult) {
        teardown()
        SelectionOverlayController.resetCursorToArrow()
        onResult?(result)
    }
    private weak var ownerWindow: OverlayWindow?
    private var frozenNSImage: NSImage?

    private var dragStart: CGPoint?
    private var selection: CGRect? { didSet { needsDisplay = true } }
    private var cursorPoint: CGPoint = .zero
    private var isDragging = false

    // Режим окна.
    private var windowInfos: [WindowInfo] = []
    private var hoveredWindow: (id: CGWindowID, localRect: CGRect)?

    /// Пробел переключает в выбор окна (как в системной ⌘⇧4 → Пробел): для видео —
    /// записать окно, для области — снять окно целиком. В подрежиме ведём себя как .window.
    private var windowSubmode = false
    private var isWindowSelecting: Bool { mode == .window || windowSubmode }
    /// Пробел: контроллер синхронизирует подрежим на всех мониторах.
    var onToggleWindowSubmode: (() -> Void)?

    func setWindowSubmode(_ on: Bool) {
        guard mode != .window, windowSubmode != on else { return }
        windowSubmode = on
        selection = nil
        dragStart = nil
        if on {
            // Пересканируем при каждом входе в подрежим: окна могли открыться/сдвинуться,
            // пока оверлей был в режиме области — иначе подсветка ложится по устаревшим рамкам.
            windowInfos = ScreenCapturer.onscreenWindows().filter { $0.frameCocoa.intersects(screenRef.frame) }
            updateHoveredWindow()
        } else {
            hoveredWindow = nil
        }
        needsDisplay = true
    }

    init(frame: NSRect, screen: NSScreen, mode: Mode) {
        self.screenRef = screen
        self.mode = mode
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func attachWindow(_ window: OverlayWindow) {
        ownerWindow = window
        cursorPoint = CGPoint(x: NSEvent.mouseLocation.x - screenRef.frame.minX,
                              y: NSEvent.mouseLocation.y - screenRef.frame.minY)
        if mode == .window { updateHoveredWindow() }
        // Курсор-мишень ставим СРАЗУ: оверлей появляется под неподвижной мышью, поэтому
        // mouseEntered не срабатывает (граница возникает под курсором) — без явной установки
        // курсор остаётся стрелкой до первого движения.
        let cur = activeCursor
        cur.set()
        DispatchQueue.main.async {
            window.makeFirstResponder(self)
            cur.set()
        }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    func provideWindows(_ infos: [WindowInfo]) {
        windowInfos = infos.filter { $0.frameCocoa.intersects(screenRef.frame) }
        needsDisplay = true
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { if !dismissed { addCursorRect(bounds, cursor: activeCursor) } }
    override func cursorUpdate(with event: NSEvent) { if !dismissed { activeCursor.set() } }

    /// Курсор под текущий режим: «мишень» для выбора области, «камера» — для выбора окна
    /// (ровно как в системной скриншотилке ⌘⇧4 / ⌘⇧4-Пробел).
    private var activeCursor: NSCursor { isWindowSelecting ? Self.windowCursor : Self.reticleCursor }

    /// Системный курсор по имени из HIServices: тот же ресурс, что использует сам macOS,
    /// — векторный cursor.pdf (чёткий на Retina), hotspot из info.plist. Полное совпадение
    /// с оригиналом. Если ресурс недоступен — рисуем близкий фолбэк.
    private static func systemCursor(_ name: String, fallback: () -> NSCursor) -> NSCursor {
        let base = "/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/HIServices.framework/Versions/A/Resources/cursors"
        let dir = "\(base)/\(name)"
        guard let img = NSImage(contentsOfFile: "\(dir)/cursor.pdf"), img.size.width > 0 else {
            return fallback()
        }
        // ВАЖНО: cursor.pdf — векторный (только NSPDFImageRep). NSCursor из такой картинки
        // рисуется ПУСТЫМ. Растеризуем в битмап @2x (чётко на Retina), иначе курсора нет.
        // Сам ресурс целиком тёмный (замер: 0 светлых пикселей) → на тёмном фоне не виден.
        // Накладываем ТОНЧАЙШУЮ светлую тень (blur 1, alpha 0.4, один проход) — повторяет
        // системную тень курсора, чтобы мишень читалась, не превращаясь в «свечение».
        // margin — запас, чтобы кант не обрезался.
        let size = img.size
        let margin: CGFloat = 2
        let outSize = NSSize(width: size.width + margin * 2, height: size.height + margin * 2)
        let scale = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(outSize.width) * scale,
                                         pixelsHigh: Int(outSize.height) * scale,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return fallback() }
        rep.size = outSize
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.white.withAlphaComponent(0.4)
        shadow.shadowBlurRadius = 1
        shadow.shadowOffset = .zero
        shadow.set()
        img.draw(in: NSRect(x: margin, y: margin, width: size.width, height: size.height))
        NSGraphicsContext.restoreGraphicsState()
        let raster = NSImage(size: outSize)
        raster.addRepresentation(rep)
        // Hotspot — из info.plist ресурса (top-left координаты + наш margin). НЕ центр:
        // у «прицела» он (15,15), у «камеры» — (14,11); с центром картинка вставала со
        // сдвигом, и курсор «прыгал» при смене стрелки на прицел.
        var hot = NSPoint(x: outSize.width / 2, y: outSize.height / 2)
        if let plist = NSDictionary(contentsOfFile: "\(dir)/info.plist"),
           let hx = (plist["hotx"] as? NSNumber)?.doubleValue,
           let hy = (plist["hoty"] as? NSNumber)?.doubleValue {
            hot = NSPoint(x: hx + margin, y: hy + margin)
        }
        return NSCursor(image: raster, hotSpot: hot)
    }

    /// Курсор-«мишень» выбора области (системный `screenshotselection`).
    /// Фолбэк один-в-один со стандартом: тёмно-серый крестик + кольцо, БЕЗ белой обводки
    /// (замер эталона Apple: сплошь тёмные пиксели, макс. яркость ~0.2, белого нет).
    static let reticleCursor: NSCursor = systemCursor("screenshotselection") {
        let s: CGFloat = 30
        let img = NSImage(size: NSSize(width: s, height: s))
        img.lockFocus()
        let mid = s / 2
        let ink = NSColor(white: 0.15, alpha: 1)
        let line = NSBezierPath()
        line.move(to: CGPoint(x: 2, y: mid)); line.line(to: CGPoint(x: s - 2, y: mid))
        line.move(to: CGPoint(x: mid, y: 2)); line.line(to: CGPoint(x: mid, y: s - 2))
        let ring = NSBezierPath(ovalIn: CGRect(x: mid - 7, y: mid - 7, width: 14, height: 14))
        ink.setStroke()
        line.lineWidth = 1.5; line.stroke(); ring.lineWidth = 1.5; ring.stroke()
        img.unlockFocus()
        return NSCursor(image: img, hotSpot: NSPoint(x: mid, y: mid))
    }

    /// Курсор-«камера» выбора окна (системный `screenshotwindow`).
    static let windowCursor: NSCursor = systemCursor("screenshotwindow") { reticleCursor }

    // MARK: - Mouse

    override func mouseEntered(with event: NSEvent) { if !dismissed { activeCursor.set() } }

    override func mouseMoved(with event: NSEvent) {
        guard !dismissed else { return }
        cursorPoint = convert(event.locationInWindow, from: nil)
        if isWindowSelecting { updateHoveredWindow() }
        activeCursor.set()   // переустанавливаем: иначе при перерисовке курсор слетает на стрелку
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard !dismissed else { return }
        let p = convert(event.locationInWindow, from: nil)
        cursorPoint = p
        if isWindowSelecting {
            updateHoveredWindow()
            if let hovered = hoveredWindow { selectWindow(hovered) }
            return
        }
        dragStart = p
        isDragging = true
        selection = CGRect(origin: p, size: .zero)
        activeCursor.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dismissed else { return }
        guard !isWindowSelecting, let start = dragStart else { return }
        let p = convert(event.locationInWindow, from: nil)
        cursorPoint = p
        selection = rect(from: start, to: p)
        activeCursor.set()   // удерживаем «мишень» в процессе выделения (перерисовка её сбрасывала)
    }

    override func mouseUp(with event: NSEvent) {
        guard !dismissed else { return }
        guard !isWindowSelecting else { return }
        isDragging = false
        dragStart = nil
        // Перетаскивание vs клик: реальным выделением считаем сдвиг хотя бы на ~3pt по любой
        // оси — тогда снимаем даже маленькую/тонкую область. Иначе это просто клик.
        let isDrag = selection.map { max($0.width, $0.height) >= 3 } ?? false
        if isDrag, let sel = selection {
            if mode == .video { emitVideoArea(local: sel) } else { confirmArea(sel) }
        } else if mode == .video {
            // Видео: клик без выделения — записываем весь экран (как договорились).
            complete(.videoArea(screenRef.frame, screenRef))
        } else {
            // Скриншот: клик без выделения — отменяем, как в стандартной скриншотилке macOS
            // (а не «зависаем» в оверлее в ожидании).
            complete(.cancelled)
        }
    }

    /// Вырезка из «замороженного» кадра в пиксельных координатах.
    private func cropFrozen(_ sel: CGRect) -> CGImage? {
        guard let frozen = frozenImage else { return nil }
        let scale = screenRef.backingScaleFactor
        let localTop = bounds.height - sel.maxY
        let px = CGRect(x: sel.minX * scale, y: localTop * scale,
                        width: sel.width * scale, height: sel.height * scale).integral
            .intersection(CGRect(x: 0, y: 0, width: frozen.width, height: frozen.height))
        guard px.width >= 1, px.height >= 1 else { return nil }
        return frozen.cropping(to: px)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:                                   // Esc — отмена
            complete(.cancelled)
        // Пробел — переключить «окно ↔ область» (как в ⌘⇧4). Во время растягивания
        // рамки игнорируем: иначе начатое выделение молча пропадало бы (в системной
        // скриншотилке Пробел в этот момент двигает рамку — не наш случай).
        case 49 where mode != .window && dragStart == nil:
            onToggleWindowSubmode?()               // контроллер применит подрежим ко всем мониторам
        default:
            break
        }
    }

    /// Выбор окна: для видео — записываем его область, для скриншота — отдаём id окна.
    private func selectWindow(_ hovered: (id: CGWindowID, localRect: CGRect)) {
        if mode == .video {
            let g = CGRect(x: hovered.localRect.minX + screenRef.frame.minX,
                           y: hovered.localRect.minY + screenRef.frame.minY,
                           width: hovered.localRect.width, height: hovered.localRect.height)
            complete(.videoArea(g, screenRef))
        } else {
            complete(.window(hovered.id))
        }
    }

    private func emitVideoArea(local sel: CGRect) {
        let g = CGRect(x: sel.minX + screenRef.frame.minX, y: sel.minY + screenRef.frame.minY,
                       width: sel.width, height: sel.height)
        complete(.videoArea(g, screenRef))
    }

    private func confirmArea(_ sel: CGRect) {
        // Заморозка: вырезаем сразу из кадра. Иначе — живой режим (вырезка после закрытия).
        if let cropped = cropFrozen(sel) {
            complete(.image(cropped, screenRef.backingScaleFactor))
            return
        }
        let global = CGRect(x: sel.minX + screenRef.frame.minX,
                            y: sel.minY + screenRef.frame.minY,
                            width: sel.width, height: sel.height)
        complete(.area(global, screenRef))
    }

    // MARK: - Window hover

    private func updateHoveredWindow() {
        let globalPoint = CGPoint(x: cursorPoint.x + screenRef.frame.minX,
                                  y: cursorPoint.y + screenRef.frame.minY)
        // Верхнее окно под курсором (windowInfos идёт front→back) — то, что реально
        // видно. Раньше брали наименьшее по площади → ловило перекрытые фоновые окна.
        let found = windowInfos.first { $0.frameCocoa.contains(globalPoint) }
        if let f = found {
            let local = CGRect(x: f.frameCocoa.minX - screenRef.frame.minX,
                               y: f.frameCocoa.minY - screenRef.frame.minY,
                               width: f.frameCocoa.width, height: f.frameCocoa.height)
            hoveredWindow = (f.id, local)
        } else {
            hoveredWindow = nil
        }
    }

    // MARK: - Geometry

    private func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let scale = screenRef.backingScaleFactor

        if isWindowSelecting {
            // Как в стандартном выборе окна (⌘⇧4/⌘⇧5 → Space): окно под курсором
            // подсвечивается полупрозрачной голубой заливкой, экран НЕ затемняется.
            if let h = hoveredWindow?.localRect {
                NSColor.systemBlue.withAlphaComponent(0.22).setFill()
                NSBezierPath(rect: h).fill()
                drawFrame(h)
            }
            if mode == .video {
                drawHint(NSLocalizedString("Кликните по окну для записи · Пробел — назад · Esc — отмена", comment: ""))
            } else if mode == .area {
                // Подрежим по Пробелу из выбора области: подсказываем обратный путь.
                drawHint(NSLocalizedString("Кликните по окну — снимок · Пробел — назад · Esc — отмена", comment: ""))
            }
            return
        }

        guard let sel = selection else {
            if mode == .video {
                // По умолчанию выбран весь экран: рамка по краю + подсказка.
                // Клик — запись всего экрана; перетаскивание — область; Пробел — окно.
                drawFrame(bounds.insetBy(dx: 1, dy: 1))
                drawHint(NSLocalizedString("Перетащите — записать область · Пробел — выбрать окно · клик — весь экран", comment: ""))
            }
            // Область: до начала drag НИЧЕГО не рисуем — только курсор-прицел, ровно как в
            // ⌘⇧4. Раньше рисовали ещё и крест на весь экран по cursorPoint: он не совпадал
            // с центром курсора-прицела (hotspot) → казалось, что курсор «смещается».
            return
        }

        // Один в один со стандартной скриншотилкой macOS: внутри выделения — полупрозрачный
        // НЕЙТРАЛЬНЫЙ СЕРЫЙ налёт (white 0.5, alpha 0.265). Замерено регрессией по эталону
        // (sel = base·0.735 + 127.5·0.265, одинаково по R/G/B). Серый темнит светлый фон и
        // осветляет тёмный → виден на любом фоне; раньше был почти белый и сливался на белом.
        //
        // ИНВАРИАНТ: экран не должен «дёргаться». Замороженный кадр рисуем ТОЛЬКО внутри
        // выделения: полноэкранная подмена живого экрана замороженным кадром (при начале
        // drag) и обратно (после снятия) читалась как дёрганье/мерцание всего экрана.
        // Внутри рамки при этом виден ровно тот кадр, который будет снят.
        if let frozenNSImage {
            frozenNSImage.draw(in: sel, from: sel, operation: .sourceOver, fraction: 1)
        }
        NSColor(white: 0.5, alpha: 0.265).setFill()   // налёт выделения как в macOS
        NSBezierPath(rect: sel).fill()
        drawFrame(sel)
        drawSizeBadge(for: sel, scale: scale)
    }

    /// Тонкая белая рамка 1pt — один в один со стандартной скриншотилкой macOS.
    private func drawFrame(_ r: CGRect) {
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: r)
        border.lineWidth = 1
        border.stroke()
    }

    /// Подсказка-пилюля по центру снизу — как в стандартной записи macOS.
    private func drawHint(_ text: String) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor(white: 0.1, alpha: 1),
        ]
        let tsize = (text as NSString).size(withAttributes: attrs)
        let padX: CGFloat = 18, padY: CGFloat = 12
        let w = tsize.width + padX * 2, h = tsize.height + padY * 2
        let badge = CGRect(x: (bounds.width - w) / 2, y: bounds.height * 0.14, width: w, height: h)
        let bg = NSBezierPath(roundedRect: badge, xRadius: h / 2, yRadius: h / 2)
        NSColor(white: 0.93, alpha: 0.96).setFill(); bg.fill()
        (text as NSString).draw(at: CGPoint(x: badge.minX + padX, y: badge.minY + padY), withAttributes: attrs)
    }

    private func drawSizeBadge(for r: CGRect, scale: CGFloat) {
        let w = Int((r.width * scale).rounded()), h = Int((r.height * scale).rounded())
        let text = "\(w) × \(h)"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: Theme.textPrimary,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let padX: CGFloat = 8, padY: CGFloat = 4
        var badge = CGRect(x: r.minX, y: r.maxY + 8,
                           width: size.width + padX * 2, height: size.height + padY * 2)
        if badge.maxY > bounds.maxY - 4 { badge.origin.y = r.maxY - badge.height - 8 } // внутрь, если не влезает сверху
        if badge.maxX > bounds.maxX { badge.origin.x = bounds.maxX - badge.width - 4 }
        badge.origin.x = max(4, badge.origin.x)

        let bg = NSBezierPath(roundedRect: badge, xRadius: Theme.Radius.sm, yRadius: Theme.Radius.sm)
        Theme.surface.setFill(); bg.fill()
        Theme.surfaceStroke.setStroke(); bg.lineWidth = 1; bg.stroke()
        (text as NSString).draw(at: CGPoint(x: badge.minX + padX, y: badge.minY + padY), withAttributes: attrs)
    }
}
