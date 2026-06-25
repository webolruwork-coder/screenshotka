import AppKit
import ScreenCaptureKit

/// «Прокрутка захвата»: длинный снимок прокручиваемого окна. Прокручивает окно
/// синтетическими событиями, снимает кадры и склеивает их в одно высокое изображение,
/// определяя вертикальный сдвиг между кадрами (склейка без дублей).
///
/// Требует доступ «Универсальный доступ» (Accessibility) — без него синтетический скролл
/// не доходит до других приложений.
enum ScrollingCapture {

    static func isTrusted() -> Bool { AXIsProcessTrusted() }

    /// Показать системный запрос доступа Accessibility.
    static func requestTrust() {
        let opt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opt)
    }

    /// Снять прокручиваемое окно целиком.
    static func capture(windowID: CGWindowID, cocoaFrame: CGRect) async throws -> CGImage {
        // Курсор в центр окна — туда уйдут события скролла.
        let center = CGPoint(x: cocoaFrame.midX, y: cocoaFrame.midY)
        warpCursor(toCocoa: center)
        try? await Task.sleep(nanoseconds: 150_000_000)

        var frames: [CGImage] = [try await ScreenCapturer.capture(windowID: windowID)]
        var grays: [GrayBuf] = [GrayBuf(frames[0])]
        let H = frames[0].height
        // Шаг прокрутки в точках — ~72% высоты окна (перекрытие ~28% для надёжной склейки;
        // с запасом меньше maxS детектора сдвига).
        let scrollPoints = max(60, Int(cocoaFrame.height * 0.72))
        let maxFrames = 60
        var dryRounds = 0

        for _ in 0..<maxFrames {
            postScrollDown(points: scrollPoints, atCocoa: center)
            try? await Task.sleep(nanoseconds: 230_000_000)
            let img = try await ScreenCapturer.capture(windowID: windowID)
            let g = GrayBuf(img)
            // Низ достигнут, если кадр почти не изменился — выходим после 2 таких подряд.
            if g.sadFull(grays.last!) < 5 {
                dryRounds += 1
                if dryRounds >= 2 { break }
                continue
            }
            dryRounds = 0
            frames.append(img); grays.append(g)
        }
        guard frames.count > 1 else { return frames[0] }

        var shifts: [Int] = []
        for i in 1..<frames.count {
            shifts.append(grays[i-1].verticalShift(to: grays[i]))
        }
        return stitch(frames, shifts: shifts, frameHeight: H)
    }

    // MARK: - Склейка

    private static func stitch(_ frames: [CGImage], shifts: [Int], frameHeight H: Int) -> CGImage {
        let W = frames[0].width
        let totalH = H + shifts.reduce(0, +)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: W, height: totalH, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return frames[0]
        }
        // CGContext: origin внизу-слева. Кладём первый кадр сверху, затем нижние полосы.
        var topY = totalH                       // верхняя граница заполненного (в коорд. контекста)
        ctx.draw(frames[0], in: CGRect(x: 0, y: topY - H, width: W, height: H))
        topY -= H
        for i in 1..<frames.count {
            let s = shifts[i-1]
            guard s > 0, s <= H,
                  let strip = frames[i].cropping(to: CGRect(x: 0, y: H - s, width: W, height: s)) else { continue }
            ctx.draw(strip, in: CGRect(x: 0, y: topY - s, width: W, height: s))
            topY -= s
        }
        return ctx.makeImage() ?? frames[0]
    }

    // MARK: - Скролл / курсор

    private static func warpCursor(toCocoa p: CGPoint) {
        // Cocoa (origin внизу-слева, глобально) → CG глобальные (origin сверху-слева).
        // Флип считаем от высоты ОСНОВНОГО экрана (screens.first — тот, что в (0,0)):
        // CG-origin привязан именно к нему. Брать max maxY по всем мониторам нельзя —
        // если второй дисплей стоит ВЫШЕ основного, курсор уезжал на его высоту вниз,
        // и скролл-события уходили мимо окна (длинный снимок молча не работал).
        let primaryH = NSScreen.screens.first?.frame.maxY ?? 0
        CGWarpMouseCursorPosition(CGPoint(x: p.x, y: primaryH - p.y))
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    private static func postScrollDown(points: Int, atCocoa p: CGPoint) {
        // Дробим на шаги, чтобы скролл шёл плавно и приложение успевало рендерить.
        let steps = 6
        let per = Int32(-(points / steps))   // минус — вниз
        for _ in 0..<steps {
            guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                  wheelCount: 1, wheel1: per, wheel2: 0, wheel3: 0) else { continue }
            e.post(tap: .cghidEventTap)
            usleep(8000)
        }
    }
}

/// Уменьшенный по ширине grayscale-буфер кадра (полная высота) для матчинга сдвига.
private struct GrayBuf {
    let w: Int, h: Int
    let px: [UInt8]

    init(_ cg: CGImage) {
        let sw = min(cg.width, 220)
        let sh = cg.height
        var buf = [UInt8](repeating: 0, count: max(1, sw * sh))
        let cs = CGColorSpaceCreateDeviceGray()
        buf.withUnsafeMutableBytes { ptr in
            if let ctx = CGContext(data: ptr.baseAddress, width: sw, height: sh, bitsPerComponent: 8,
                                   bytesPerRow: sw, space: cs, bitmapInfo: CGImageAlphaInfo.none.rawValue) {
                // Память bitmap-контекста хранится сверху-вниз: row 0 = визуальный ВЕРХ (проверено).
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: sw, height: sh))
            }
        }
        self.w = sw; self.h = sh; self.px = buf
    }

    /// Средняя абсолютная разница по выборке строк (0…255). Маленькое значение = кадры совпадают.
    func sadFull(_ o: GrayBuf) -> Int {
        guard w == o.w, h == o.h, h > 0 else { return 999 }
        var sum = 0, cnt = 0
        var y = 0
        while y < h {
            let a = y * w, b = y * w
            var x = 0
            while x < w { sum += abs(Int(px[a+x]) - Int(o.px[b+x])); cnt += 1; x += 3 }
            y += 8
        }
        return cnt > 0 ? sum / cnt : 999
    }

    /// Вертикальный сдвиг s (в пикселях), на который контент уехал вверх от self (раннего
    /// кадра) к o (следующему, прокрученному вниз). Берём НИЖНЮЮ полосу self (она ниже
    /// любых фиксированных шапок) и ищем её в o — это ловит и крупные сдвиги, и не путается
    /// с фикс-шапками сверху.
    func verticalShift(to o: GrayBuf) -> Int {
        guard w == o.w, h == o.h else { return 0 }
        let band = min(120, h / 7)            // не выше ~14% кадра, чтобы maxS покрывал крупные сдвиги
        let aTop = h - band                   // нижняя полоса раннего кадра self
        let minS = max(8, h / 14)
        let maxS = h - band - 1               // s такой, что полоса в o не вылезает за верх
        guard maxS > minS else { return 0 }

        func sad(_ s: Int) -> Int {
            let bTop = h - s - band           // где эта полоса оказалась в o
            if bTop < 0 { return Int.max }
            var sum = 0, cnt = 0, dy = 0
            while dy < band {
                let ai = (aTop + dy) * w
                let bi = (bTop + dy) * o.w
                var x = 0
                while x < w { sum += abs(Int(px[ai+x]) - Int(o.px[bi+x])); cnt += 1; x += 2 }
                dy += 2
            }
            return cnt > 0 ? sum / cnt : 999
        }
        // Полный поиск шагом 1: у резкого контента минимум SAD может быть «острым»
        // (1 px), грубый шаг его промахивает. Стоимость мала (sad() уже прорежен по x/y).
        var best = minS, bestVal = Int.max
        var s = minS
        while s <= maxS { let v = sad(s); if v < bestVal { bestVal = v; best = s }; s += 1 }
        // Нет уверенного совпадения — прокрутки фактически не было (или контент сменился).
        return bestVal < 26 ? best : 0
    }
}
