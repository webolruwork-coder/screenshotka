import AppKit
import ScreenCaptureKit

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }
}

/// Информация об окне для режима «снять окно» (для подсветки под курсором).
struct WindowInfo {
    let id: CGWindowID
    let frameCocoa: CGRect   // глобальные координаты Cocoa (origin внизу-слева)
    let area: CGFloat
}

/// Захват экрана через ScreenCaptureKit (SCScreenshotManager).
/// Собственное приложение исключается из кадра, поэтому оверлей и плашки в снимок не попадают.
enum ScreenCapturer {

    enum CaptureError: LocalizedError {
        case noDisplay, noWindow, cropFailed
        var errorDescription: String? {
            switch self {
            case .noDisplay: return NSLocalizedString("Не найден дисплей для захвата.", comment: "")
            case .noWindow: return NSLocalizedString("Окно недоступно для захвата.", comment: "")
            case .cropFailed: return NSLocalizedString("Не удалось обрезать область.", comment: "")
            }
        }
    }

    /// Снимок прямоугольной области (координаты Cocoa, origin внизу-слева).
    /// Снимаем весь дисплей и обрезаем в пиксельных координатах — предсказуемая геометрия.
    static func capture(rectInScreen rect: CGRect, on screen: NSScreen) async throws -> CGImage {
        let scale = screen.backingScaleFactor
        let full = try await captureFullscreen(screen: screen)

        let localX = rect.minX - screen.frame.minX          // от левого края экрана
        let localTop = screen.frame.maxY - rect.maxY        // от верхнего края экрана
        var pixelRect = CGRect(x: localX * scale, y: localTop * scale,
                               width: rect.width * scale, height: rect.height * scale).integral
        // Клампим в границы кадра.
        pixelRect = pixelRect.intersection(CGRect(x: 0, y: 0, width: full.width, height: full.height))
        guard pixelRect.width >= 1, pixelRect.height >= 1, let cropped = full.cropping(to: pixelRect) else {
            throw CaptureError.cropFailed
        }
        return cropped
    }

    /// Снимок всего экрана. Курсор НИКОГДА не включаем: стандартные снимки macOS его не
    /// содержат, а SCScreenshotManager с showsCursor=true рисует курсор в левом верхнем
    /// углу кадра (баг ScreenCaptureKit для still-захвата). Параметр оставлен для совместимости.
    static func captureFullscreen(screen: NSScreen, showsCursor: Bool? = nil) async throws -> CGImage {
        let content = try await shareableContent()
        guard let display = display(for: screen, in: content) else { throw CaptureError.noDisplay }
        let scale = screen.backingScaleFactor

        let filter = SCContentFilter(display: display,
                                     excludingApplications: ownApplications(in: content),
                                     exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = Int((CGFloat(display.width) * scale).rounded())
        config.height = Int((CGFloat(display.height) * scale).rounded())
        config.showsCursor = false
        config.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// Снимок окна по его идентификатору (ScreenCaptureKit).
    ///
    /// С тенью: холсту SCK нельзя задать размер «окно+тень» напрямую — размеры системной
    /// тени нигде не публикуются, а холст размером с окно заставлял SCK ужимать в него
    /// окно вместе с тенью (кривые отступы, «сплюснутая» тень). Замерено (лаборатория):
    /// если холст БОЛЬШЕ контента, SCK кладёт «окно+тень» 1:1 без масштабирования,
    /// прижав к верхнему-левому углу. Поэтому снимаем с запасом и обрезаем по отступам,
    /// замеренным на самом кадре — самокалибровка, без захардкоженных размеров тени
    /// (переживёт смену теней в будущих macOS). Итог совпадает с ⌘⇧4 → Пробел.
    static func capture(windowID: CGWindowID) async throws -> CGImage {
        let content = try await shareableContent()
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError.noWindow
        }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let wPx = Int((window.frame.width * scale).rounded())
        let hPx = Int((window.frame.height * scale).rounded())
        let includeShadow = Settings.shared.screenshotWindowShadow
        // Запас под тень: сегодняшняя системная ~112px @2x, берём с многократным запасом.
        let pad = includeShadow ? Int(300 * scale) : 0
        config.width = wPx + pad
        config.height = hPx + pad
        config.showsCursor = false   // курсор в снимок не включаем (как в стандартной скриншотилке)
        config.ignoreShadowsSingleWindow = !includeShadow
        config.backgroundColor = .clear
        config.captureResolution = .best
        let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        guard includeShadow else { return img }
        return cropToSystemShadowCanvas(img, windowPxW: wPx, windowPxH: hPx) ?? img
    }

    /// Обрезка кадра «окно+тень с запасом» до системного холста (как у ⌘⇧4 → Пробел).
    ///
    /// Контент прижат к верхнему-левому углу. Отступы слева (L) и сверху (T) меряем по
    /// резкой непрозрачной кромке окна; справа тень симметрична (R = L); снизу — из
    /// геометрии системной тени «гауссов блюр радиуса r со сдвигом d вниз»:
    /// L = R = r, T = r − d, B = r + d ⇒ B = 2L − T. Сходится с реальными полями
    /// системной скриншотилки (111/111/76/147 @2x) с точностью ±1px.
    private static func cropToSystemShadowCanvas(_ img: CGImage, windowPxW: Int, windowPxH: Int) -> CGImage? {
        let W = img.width, H = img.height
        guard W > 0, H > 0,
              let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8,
                                  bytesPerRow: W * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H))
        guard let data = ctx.data else { return nil }
        let px = data.bindMemory(to: UInt8.self, capacity: W * H * 4)
        // Память контекста: row 0 = визуальный ВЕРХ (см. GrayBuf в ScrollingCapture).
        func opaque(_ x: Int, _ y: Int) -> Bool { px[(y * W + x) * 4 + 3] >= 250 }

        // L: первый столбец с непрозрачным пикселем (боковые кромки окна вертикальны).
        var L = -1
        outerL: for x in 0..<min(W, windowPxW) {
            var y = 0
            while y < H { if opaque(x, y) { L = x; break outerL }; y += 5 }
        }
        // T: первая строка с непрозрачным пикселем (верхняя кромка горизонтальна).
        var T = -1
        outerT: for y in 0..<min(H, windowPxH) {
            var x = 0
            while x < W { if opaque(x, y) { T = y; break outerT }; x += 5 }
        }
        guard L >= 0, T >= 0, T <= L else { return nil }   // у системной тени всегда T < L (сдвиг вниз)
        let B = 2 * L - T
        let cw = min(W, windowPxW + 2 * L)
        let ch = min(H, windowPxH + T + B)
        return img.cropping(to: CGRect(x: 0, y: 0, width: cw, height: ch))
    }

    /// Список окон на экране в порядке сверху вниз (front→back) — для подсветки под
    /// курсором. Только реально видимые окна: непрозрачные, на экране, обычного слоя.
    static func onscreenWindows() -> [WindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier

        var result: [WindowInfo] = []
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32, pid != ownPID,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width > 40, bounds.height > 40 else { continue }
            // Только видимые: непрозрачные и реально на экране (отсекаем скрытые
            // служебные/прозрачные окна, которые пользователь не видит).
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
            let onscreen = info[kCGWindowIsOnscreen as String] as? Bool ?? true
            guard alpha > 0.1, onscreen else { continue }
            guard let frame = cocoaFrame(forCGWindowBounds: bounds) else { continue }
            result.append(WindowInfo(id: id, frameCocoa: frame, area: bounds.width * bounds.height))
        }
        return result   // порядок CGWindowList — front→back
    }

    // MARK: - Private

    private static func shareableContent() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    }

    private static func display(for screen: NSScreen, in content: SCShareableContent) -> SCDisplay? {
        guard let number = screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber else { return nil }
        let displayID = CGDirectDisplayID(number.uint32Value)
        return content.displays.first { $0.displayID == displayID }
    }

    private static func ownApplications(in content: SCShareableContent) -> [SCRunningApplication] {
        let pid = ProcessInfo.processInfo.processIdentifier
        return content.applications.filter { $0.processID == pid }
    }

    /// CGWindowList отдаёт bounds в координатах CoreGraphics конкретного дисплея
    /// (origin сверху-слева). Переводим в Cocoa NSScreen.frame (origin снизу-слева),
    /// иначе выбор окна ломается на внешних мониторах и нестандартной раскладке.
    private static func cocoaFrame(forCGWindowBounds bounds: CGRect) -> CGRect? {
        let displayPairs: [(screen: NSScreen, cgBounds: CGRect)] = NSScreen.screens.compactMap { screen in
            guard let displayID = screen.displayID else { return nil }
            return (screen, CGDisplayBounds(displayID))
        }
        guard !displayPairs.isEmpty else { return nil }

        let display = displayPairs.max { lhs, rhs in
            lhs.cgBounds.intersection(bounds).area < rhs.cgBounds.intersection(bounds).area
        } ?? displayPairs[0]

        let localX = bounds.minX - display.cgBounds.minX
        let localYFromTop = bounds.minY - display.cgBounds.minY
        return CGRect(x: display.screen.frame.minX + localX,
                      y: display.screen.frame.maxY - localYFromTop - bounds.height,
                      width: bounds.width,
                      height: bounds.height)
    }
}

private extension CGRect {
    var area: CGFloat { max(0, width) * max(0, height) }
}
