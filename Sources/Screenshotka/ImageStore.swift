import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Сохранение, копирование и подготовка снимков.
enum ImageStore {

    static func nsImage(from cg: CGImage) -> NSImage {
        NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    static func pngData(from cg: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = NSSize(width: cg.width, height: cg.height)
        return rep.representation(using: .png, properties: [:])
    }

    /// Кодирует снимок в выбранный пользователем формат (PNG/JPEG/HEIF) с сохранением
    /// цветового профиля изображения. Учитывает качество и опцию даунскейла до 1×.
    /// `scale` — реальный backingScaleFactor экрана, с которого снят кадр: на 1×-мониторах
    /// даунскейл не выполняется (иначе портили бы качество уже-1× снимков).
    /// Возвращает данные и фактическое расширение файла. PNG — без потерь.
    static func encodedData(from cg: CGImage, scale: CGFloat = 2) -> (data: Data, ext: String)? {
        let fmt = Settings.shared.screenshotFormat
        var image = cg
        if Settings.shared.screenshotScaleTo1x, scale > 1.01 {
            image = downscaled(cg, factor: 1.0 / scale)
        }
        // JPEG не умеет прозрачность: без подложки прозрачные углы/тень окна станут
        // чёрными. Композитим на белый. (HEIF и PNG сохраняют альфу как есть.)
        if fmt == .jpeg { image = flattenedOnWhite(image) }

        let type: CFString
        switch fmt {
        case .png:  type = UTType.png.identifier as CFString
        case .jpeg: type = UTType.jpeg.identifier as CFString
        case .heif: type = UTType.heic.identifier as CFString
        }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type, 1, nil) else {
            return pngData(from: image).map { ($0, "png") }   // откат
        }
        var props: [CFString: Any] = [:]
        if fmt.isLossy { props[kCGImageDestinationLossyCompressionQuality] = Settings.shared.screenshotQuality }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            // HEIC может быть недоступен на части машин — откатываемся на PNG.
            return pngData(from: image).map { ($0, "png") }
        }
        return (out as Data, fmt.ext)
    }

    /// Пропорциональное уменьшение (factor < 1) с качественной интерполяцией.
    private static func downscaled(_ cg: CGImage, factor: CGFloat) -> CGImage {
        guard factor < 0.999 else { return cg }
        let w = max(1, Int((CGFloat(cg.width) * factor).rounded()))
        let h = max(1, Int((CGFloat(cg.height) * factor).rounded()))
        guard let cs = cg.colorSpace,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: cg.bitmapInfo.rawValue) else { return cg }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? cg
    }

    /// Композит на белую подложку (для JPEG). Если альфы нет — возвращает как есть.
    private static func flattenedOnWhite(_ cg: CGImage) -> CGImage {
        switch cg.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return cg
        default: break
        }
        let cs = cg.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: nil, width: cg.width, height: cg.height,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: info) else { return cg }
        let rect = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(rect)
        ctx.draw(cg, in: rect)
        return ctx.makeImage() ?? cg
    }

    static func cgImage(from url: URL) -> CGImage? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        var rect = NSRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    @discardableResult
    static func copyToClipboard(_ cg: CGImage) -> Bool {
        guard let data = pngData(from: cg) else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()
        // Объявляем оба типа и кладём данные: PNG (для редакторов) и TIFF (для совместимости).
        pb.declareTypes([.png, .tiff], owner: nil)
        pb.setData(data, forType: .png)
        if let tiff = nsImage(from: cg).tiffRepresentation {
            pb.setData(tiff, forType: .tiff)
        }
        return true
    }

    @discardableResult
    static func copyFileToClipboard(_ url: URL) -> Bool {
        let pb = NSPasteboard.general
        pb.clearContents()
        return pb.writeObjects([url as NSURL])
    }

    /// Имя файла без расширения. Используем исторический ключ локализации
    /// «Снимок %@.png» (переводы уже есть в en/es) и срезаем «.png».
    static func nameStem() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = NSLocalizedString("yyyy-MM-dd 'в' HH.mm.ss", comment: "")
        let localized = String(format: NSLocalizedString("Снимок %@.png", comment: ""), fmt.string(from: Date()))
        return (localized as NSString).deletingPathExtension
    }

    static func defaultName(ext: String = "png") -> String {
        nameStem() + ".\(ext)"
    }

    /// Уникальный путь: добавляет « (2)», « (3)» … если файл уже существует.
    /// Иначе два снимка за одну секунду молча перезаписывали бы друг друга.
    static func uniqueURL(in folder: URL, name: String, ext: String) -> URL {
        var url = folder.appendingPathComponent("\(name).\(ext)")
        var i = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(name) (\(i)).\(ext)")
            i += 1
        }
        return url
    }

    /// Атомарно-уникальная запись: .withoutOverwriting + повтор с новым суффиксом.
    /// Простой uniqueURL+write — TOCTOU: два параллельных сохранения (Task.detached)
    /// могли вычислить одно имя и молча перезаписать друг друга.
    static func writeUniquely(_ data: Data, in folder: URL, name: String, ext: String) -> URL? {
        for i in 1...1000 {
            let url = folder.appendingPathComponent(i == 1 ? "\(name).\(ext)" : "\(name) (\(i)).\(ext)")
            do {
                try data.write(to: url, options: [.withoutOverwriting])
                return url
            } catch let e as NSError where e.domain == NSCocoaErrorDomain && e.code == NSFileWriteFileExistsError {
                continue   // имя занято — пробуем следующий суффикс
            } catch {
                NSLog("Не удалось сохранить: \(error)")
                return nil
            }
        }
        return nil
    }

    /// Временный PNG для drag-and-drop из превью в другие приложения.
    /// Не удаляем сразу после drag: некоторые приложения читают файл уже после завершения drop.
    static func dragFile(for cg: CGImage) -> URL? {
        guard let data = pngData(from: cg) else { return nil }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenshotkaDrag", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            pruneDragFolder(folder)
            let url = folder.appendingPathComponent(defaultName())
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            NSLog("Не удалось подготовить файл для drag-and-drop: \(error)")
            return nil
        }
    }

    private static func pruneDragFolder(_ folder: URL) {
        let cutoff = Date(timeIntervalSinceNow: -24 * 60 * 60)
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder,
                                                                 includingPropertiesForKeys: [.contentModificationDateKey],
                                                                 options: [.skipsHiddenFiles])) ?? []
        for url in urls {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if date < cutoff { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// Тихое сохранение в папку по умолчанию. Возвращает URL.
    @discardableResult
    static func saveToDefaultFolder(_ cg: CGImage, scale: CGFloat = 2) -> URL? {
        guard let (data, ext) = encodedData(from: cg, scale: scale) else { return nil }
        return writeUniquely(data, in: Settings.shared.saveFolder, name: nameStem(), ext: ext)
    }

    /// Диалог «Сохранить как…». completion(true) — файл записан, completion(false) — отмена/ошибка.
    static func saveWithDialog(_ cg: CGImage, scale: CGFloat = 2, suggested: String? = nil,
                               in window: NSWindow? = nil, completion: ((Bool) -> Void)? = nil) {
        let panel = NSSavePanel()
        let fmt = Settings.shared.screenshotFormat
        let contentType: UTType = (fmt == .png) ? .png : (fmt == .jpeg ? .jpeg : .heic)
        panel.allowedContentTypes = [contentType]
        panel.nameFieldStringValue = suggested ?? defaultName(ext: fmt.ext)
        panel.directoryURL = Settings.shared.saveFolder
        let handler: (NSApplication.ModalResponse) -> Void = { resp in
            guard resp == .OK, var url = panel.url, let (data, ext) = encodedData(from: cg, scale: scale) else {
                completion?(false); return
            }
            // Фактический формат мог отличаться (откат HEIC→PNG) — выравниваем расширение,
            // чтобы не записать PNG-байты в файл с .heic.
            if url.pathExtension.lowercased() != ext {
                url.deletePathExtension()
                url.appendPathExtension(ext)
            }
            do { try data.write(to: url); completion?(true) }
            catch { NSLog("Сохранение не удалось: \(error)"); completion?(false) }
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            panel.begin(completionHandler: handler)
        }
    }

    /// Диалог «Сохранить видео как…» — копирует записанный файл в выбранное место.
    static func saveVideoWithDialog(_ url: URL) {
        let panel = NSSavePanel()
        if let mov = UTType(filenameExtension: url.pathExtension) { panel.allowedContentTypes = [mov] }
        panel.nameFieldStringValue = url.lastPathComponent
        panel.directoryURL = Settings.shared.saveFolder
        panel.begin { resp in
            guard resp == .OK, let dest = panel.url else { return }
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: url, to: dest)
            } catch { NSLog("Сохранение видео не удалось: \(error)") }
        }
    }
}
