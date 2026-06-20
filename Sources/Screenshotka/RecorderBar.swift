import AppKit
import AVFoundation

// MARK: - Панель управления записью (во время записи)

final class RecorderBarController {
    private let recorder: ScreenRecorder
    var onFinished: ((URL?) -> Void)?

    private var panel: NSPanel!
    private var timer: Timer?
    private var seconds = 0
    private var paused = false
    private var keyMonitor: Any?
    private var finishing = false   // защита от двойного стоп/удаления (Пробел дважды, Пробел+клик)

    private var stopButton: NSButton!
    private var pauseButton: HoverButton!

    init(recorder: ScreenRecorder) {
        self.recorder = recorder
        buildPanel()
        startTimer()
        // Пробел — остановить запись (пока приложение активно). Не перехватываем,
        // если фокус в текстовом поле нашего окна (например, открыт редактор).
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 49 {
                if NSApp.keyWindow?.firstResponder is NSText { return e }
                self?.stop(); return nil
            }
            return e
        }
    }

    deinit {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        timer?.invalidate()
        panel?.orderOut(nil)
    }

    private func buildPanel() {
        let height: CGFloat = 48
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = Theme.Radius.lg
        card.layer?.cornerCurve = .continuous
        card.layer?.backgroundColor = NSColor(white: 0.13, alpha: 0.98).cgColor
        card.layer?.borderWidth = 1
        card.layer?.borderColor = Theme.surfaceStroke.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false

        // Стоп + таймер — красная «пилюля», как кнопка «Запись» в панели опций.
        let stop = HoverButton(title: "", target: nil, action: nil)
        stop.isBordered = false
        stop.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: NSLocalizedString("Стоп", comment: ""))?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .bold))
        stop.imagePosition = .imageLeading
        stop.imageHugsTitle = true
        stop.contentTintColor = .white
        stop.restingTint = .white; stop.hoverTint = .white
        stop.wantsLayer = true
        stop.layer?.cornerRadius = Theme.Radius.sm
        stop.layer?.backgroundColor = NSColor.systemRed.cgColor
        stop.translatesAutoresizingMaskIntoConstraints = false
        stop.widthAnchor.constraint(greaterThanOrEqualToConstant: 84).isActive = true
        stop.heightAnchor.constraint(equalToConstant: 30).isActive = true
        stop.toolTip = NSLocalizedString("Остановить и сохранить", comment: "")
        stop.onAction = { [weak self] in self?.stop() }
        stopButton = stop
        updateTimerLabel()

        let pause = iconButton("pause.fill", NSLocalizedString("Пауза", comment: "")) { [weak self] in self?.togglePause() }
        pauseButton = pause
        let restart = iconButton("arrow.counterclockwise", NSLocalizedString("Начать заново", comment: "")) { [weak self] in self?.restart() }
        let del = iconButton("trash", NSLocalizedString("Удалить", comment: "")) { [weak self] in self?.deleteRecording() }
        let more = iconButton("line.3.horizontal", NSLocalizedString("Ещё", comment: "")) { [weak self] in self?.showMore() }

        // Красная «пилюля» (стоп+таймер) — СПРАВА, ровно как кнопка «Запись» в панели
        // опций: прямой переход «Запись» → «Стоп» без перескока действия слева-направо.
        // Вторичные контролы (пауза/заново/удалить/ещё) — слева.
        let row = NSStackView(views: [pause, restart, del, more, stop])
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: card.topAnchor),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        ])

        let content = NSView(frame: p.contentView!.bounds)
        content.addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: content.topAnchor),
            card.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            card.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        p.contentView = content
        p.layoutIfNeeded()
        p.setContentSize(NSSize(width: row.fittingSize.width, height: 48))

        // Низ по центру экрана с мышью.
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            let size = p.frame.size
            p.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.minY + 28))
        }
        p.orderFrontRegardless()
        self.panel = p
    }

    private func iconButton(_ symbol: String, _ tip: String, action: @escaping () -> Void) -> HoverButton {
        let b = HoverButton(title: "", target: nil, action: nil)
        b.isBordered = false
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
        b.imagePosition = .imageOnly
        b.restingTint = Theme.textPrimary
        b.hoverTint = Theme.accent
        b.toolTip = tip
        b.setAccessibilityLabel(tip)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 28).isActive = true
        b.heightAnchor.constraint(equalToConstant: 28).isActive = true
        b.onAction = action
        return b
    }

    // MARK: - Timer

    private func startTimer() {
        timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, !self.paused else { return }
            self.seconds += 1
            self.updateTimerLabel()
        }
        if let t = timer { RunLoop.main.add(t, forMode: .common) }   // тикает и при перетаскивании панели/открытом меню
    }

    private func updateTimerLabel() {
        let m = seconds / 60, s = seconds % 60
        let text = String(format: "%d:%02d", m, s)
        stopButton?.attributedTitle = NSAttributedString(string: " " + text, attributes: [
            .foregroundColor: NSColor.white,
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
        ])
    }

    // MARK: - Actions

    private func togglePause() {
        if paused {
            recorder.resume(); paused = false
            pauseButton.image = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: NSLocalizedString("Пауза", comment: ""))?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
            pauseButton.toolTip = NSLocalizedString("Пауза", comment: "")
        } else {
            recorder.pause(); paused = true
            pauseButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: NSLocalizedString("Продолжить", comment: ""))?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
            pauseButton.toolTip = NSLocalizedString("Продолжить", comment: "")
        }
    }

    /// Остановка извне (например, по горячей клавише, когда панель скрыта/видима).
    func requestStop() { stop() }

    private func stop() {
        guard !finishing else { return }
        finishing = true
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }   // Пробел больше не ловим
        timer?.invalidate()
        Task { [weak self] in
            guard let self else { return }
            let url = await self.recorder.stop()
            await MainActor.run { self.close(url: url) }
        }
    }

    private func deleteRecording() {
        guard !finishing else { return }
        finishing = true
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        timer?.invalidate()
        Task { [weak self] in
            guard let self else { return }
            await self.recorder.cancel()
            await MainActor.run { self.close(url: nil) }
        }
    }

    private func restart() {
        Task { [weak self] in
            guard let self else { return }
            try? await self.recorder.restart()
            await MainActor.run {
                self.seconds = 0
                self.paused = false
                self.updateTimerLabel()
                // Вернуть кнопку паузы в исходное состояние (если рестарт был с паузы).
                self.pauseButton.image = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: NSLocalizedString("Пауза", comment: ""))?
                    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .regular))
                self.pauseButton.toolTip = NSLocalizedString("Пауза", comment: "")
            }
        }
    }

    private func showMore() {
        let menu = NSMenu()
        let cursor = NSMenuItem(title: NSLocalizedString("Показывать курсор", comment: ""), action: #selector(toggleCursor), keyEquivalent: "")
        cursor.target = self; cursor.state = Settings.shared.showCursorInVideo ? .on : .off
        menu.addItem(cursor)
        let open = NSMenuItem(title: NSLocalizedString("Открыть папку записей", comment: ""), action: #selector(openFolder), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        if let v = panel.contentView {
            menu.popUp(positioning: nil, at: NSPoint(x: v.bounds.maxX - 40, y: v.bounds.maxY), in: v)
        }
    }
    @objc private func toggleCursor(_ s: NSMenuItem) {
        Settings.shared.showCursorInVideo.toggle()
        s.state = Settings.shared.showCursorInVideo ? .on : .off
    }
    @objc private func openFolder() { NSWorkspace.shared.open(Settings.shared.saveFolder) }

    private func close(url: URL?) {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
        onFinished?(url)
    }
}

// MARK: - Панель опций перед записью (рядом с выделенной областью)

struct RecordOptions {
    var mic: Bool
    var micDeviceID: String?
    var systemAudio: Bool
    var camera: Bool
    var cameraDeviceID: String?
}

final class RecordOptionsBar: NSObject {
    var onRecord: ((RecordOptions) -> Void)?
    var onCancel: (() -> Void)?

    private var panel: NSPanel!
    private var keyMonitor: Any?
    private var mic = Settings.shared.micEnabled
    private var micDeviceID = Settings.shared.micDeviceID
    private var sys = Settings.shared.systemAudioEnabled
    private var camera = Settings.shared.cameraEnabled
    private var cameraDeviceID = Settings.shared.cameraDeviceID
    private var micButton: HoverButton!
    private var sysButton: HoverButton!
    private var camButton: HoverButton!

    /// rect — выбранная область в глобальных координатах Cocoa.
    init(near rect: CGRect) {
        super.init()
        buildPanel(near: rect)
    }

    deinit {
        removeMonitor()
        panel?.orderOut(nil)
    }

    private func micDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified).devices
    }
    private func cameraDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
                                         mediaType: .video, position: .unspecified).devices
    }

    private func buildPanel(near rect: CGRect) {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 48),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = Theme.Radius.lg
        card.layer?.cornerCurve = .continuous
        card.layer?.backgroundColor = NSColor(white: 0.13, alpha: 0.98).cgColor
        card.layer?.borderWidth = 1
        card.layer?.borderColor = Theme.surfaceStroke.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false

        let dims = NSTextField(labelWithString: "\(Int(rect.width)) × \(Int(rect.height))")
        dims.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        dims.textColor = Theme.textSecondary

        micButton = menuButton(tip: NSLocalizedString("Микрофон", comment: "")) { [weak self] b in self?.showMicMenu(b) }
        camButton = menuButton(tip: NSLocalizedString("Камера", comment: "")) { [weak self] b in self?.showCameraMenu(b) }
        sysButton = toggleButton("speaker.wave.2.fill", "speaker.slash.fill", on: sys, tip: NSLocalizedString("Системный звук", comment: "")) { [weak self] in
            guard let self else { return }
            self.sys.toggle(); Settings.shared.systemAudioEnabled = self.sys
            self.refresh(self.sysButton, on: self.sys, on0: "speaker.wave.2.fill", off0: "speaker.slash.fill")
        }
        refreshMic()
        refreshCamera()

        let record = HoverButton(title: "", target: nil, action: nil)
        record.isBordered = false
        record.attributedTitle = NSAttributedString(string: NSLocalizedString("Запись", comment: ""), attributes: [
            .foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 13, weight: .semibold)])
        record.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: NSLocalizedString("Запись", comment: ""))?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        record.imagePosition = .imageLeading
        record.imageHugsTitle = true
        record.contentTintColor = .white
        record.restingTint = .white; record.hoverTint = .white
        record.wantsLayer = true
        record.layer?.cornerRadius = Theme.Radius.sm
        record.layer?.backgroundColor = NSColor.systemRed.cgColor
        record.translatesAutoresizingMaskIntoConstraints = false
        record.widthAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true
        record.heightAnchor.constraint(equalToConstant: 30).isActive = true
        record.onAction = { [weak self] in self?.start() }

        let close = HoverButton(title: "", target: nil, action: nil)
        close.isBordered = false
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: NSLocalizedString("Отмена", comment: ""))?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
        close.imagePosition = .imageOnly
        close.restingTint = Theme.textSecondary; close.hoverTint = Theme.textPrimary
        close.onAction = { [weak self] in self?.cancel() }

        let row = NSStackView(views: [dims, micButton, camButton, sysButton, record, close])
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: card.topAnchor),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        ])

        let content = NSView(frame: p.contentView!.bounds)
        content.addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: content.topAnchor),
            card.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            card.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        p.contentView = content
        p.layoutIfNeeded()
        p.setContentSize(NSSize(width: row.fittingSize.width, height: 48))

        // Всегда внизу по центру экрана, но над доком (visibleFrame уже исключает Dock).
        let size = p.frame.size
        let vf = (NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main)?.visibleFrame
            ?? rect
        // Та же позиция, что и у панели управления записью.
        let x = vf.midX - size.width / 2
        let y = vf.minY + 28
        p.setFrameOrigin(NSPoint(x: x, y: y))
        p.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        self.panel = p

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 {                                 // Esc — отмена
                if NSApp.keyWindow?.firstResponder is NSText { return e }   // не красть Esc у текстового поля
                self?.cancel(); return nil
            }
            // Пробел/Return — начать запись (как в системном ⌘⇧5). Не перехватываем,
            // если фокус в текстовом поле какого-то нашего окна.
            if e.keyCode == 49 || e.keyCode == 36 {
                if NSApp.keyWindow?.firstResponder is NSText { return e }
                self?.start(); return nil
            }
            return e
        }
    }

    private func removeMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    private func toggleButton(_ onSym: String, _ offSym: String, on: Bool, tip: String, action: @escaping () -> Void) -> HoverButton {
        let b = HoverButton(title: "", target: nil, action: nil)
        b.isBordered = false
        b.imagePosition = .imageOnly
        b.image = NSImage(systemSymbolName: on ? onSym : offSym, accessibilityDescription: tip)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
        b.restingTint = on ? Theme.accent : Theme.textSecondary
        b.hoverTint = Theme.accent
        b.toolTip = tip
        b.setAccessibilityLabel(tip)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 28).isActive = true
        b.heightAnchor.constraint(equalToConstant: 28).isActive = true
        b.onAction = action
        return b
    }

    private func refresh(_ b: HoverButton, on: Bool, on0: String, off0: String) {
        b.image = NSImage(systemSymbolName: on ? on0 : off0, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
        b.restingTint = on ? Theme.accent : Theme.textSecondary
    }

    private func menuButton(tip: String, action: @escaping (HoverButton) -> Void) -> HoverButton {
        let b = HoverButton(title: "", target: nil, action: nil)
        b.isBordered = false
        b.imagePosition = .imageOnly
        b.toolTip = tip
        b.setAccessibilityLabel(tip)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 28).isActive = true
        b.heightAnchor.constraint(equalToConstant: 28).isActive = true
        b.onAction = { [weak b] in if let b { action(b) } }
        return b
    }

    private func setImage(_ b: HoverButton, _ symbol: String, on: Bool) {
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
        b.restingTint = on ? Theme.accent : Theme.textSecondary
    }
    /// Кнопка показывает иконку ВЫБРАННОГО устройства (AirPods/MacBook/iPhone…),
    /// а tooltip — его имя: видно, на что именно пишется звук/видео.
    private func refreshMic() {
        let device = selectedMicDevice()
        let symbol = mic ? Self.audioSymbol(for: device?.localizedName ?? "") : "mic.slash"
        setImage(micButton, symbol, on: mic)
        micButton.toolTip = mic
            ? String(format: NSLocalizedString("Микрофон: %@", comment: ""), device?.localizedName ?? "—")
            : NSLocalizedString("Микрофон выключен", comment: "")
    }
    private func refreshCamera() {
        let device = selectedCameraDevice()
        let symbol = camera ? Self.cameraSymbol(for: device?.localizedName ?? "") : "video.slash"
        setImage(camButton, symbol, on: camera)
        camButton.toolTip = camera
            ? String(format: NSLocalizedString("Камера: %@", comment: ""), device?.localizedName ?? "—")
            : NSLocalizedString("Камера выключена", comment: "")
    }

    // MARK: - Иконки устройств (системные SF Symbols, тип — по системному имени)

    /// Символ для аудио-устройства: AirPods/MacBook/iPhone и т.д. — как в Bluetooth-меню.
    static func audioSymbol(for name: String) -> String {
        let n = name.lowercased()
        if n.contains("airpods max") { return "airpodsmax" }
        if n.contains("airpods pro") { return "airpodspro" }
        if n.contains("airpods") { return "airpods" }
        if n.contains("macbook") { return "laptopcomputer" }
        if n.contains("imac") || n.contains("display") { return "desktopcomputer" }
        if n.contains("iphone") { return "iphone" }
        if n.contains("beats") || n.contains("headphones") || n.contains("наушники") { return "headphones" }
        return "mic.fill"
    }

    /// Символ для камеры: iPhone (Continuity) / встроенная / внешняя.
    static func cameraSymbol(for name: String) -> String {
        let n = name.lowercased()
        if n.contains("iphone") { return "iphone" }
        if n.contains("facetime") || n.contains("built-in") || n.contains("macbook") { return "laptopcomputer" }
        return "web.camera"
    }

    /// Иконка пункта меню: выбранное устройство подсвечено акцентным цветом
    /// (как активное устройство в системном Bluetooth-меню).
    private func menuIcon(_ symbol: String, selected: Bool) -> NSImage? {
        guard var img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)) else { return nil }
        if selected {
            if let tinted = img.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.controlAccentColor])) {
                img = tinted
            }
        } else {
            img.isTemplate = true
        }
        return img
    }

    private func selectedMicDevice() -> AVCaptureDevice? {
        let devs = micDevices()
        if let id = micDeviceID, let d = devs.first(where: { $0.uniqueID == id }) { return d }
        return AVCaptureDevice.default(for: .audio) ?? devs.first
    }

    private func selectedCameraDevice() -> AVCaptureDevice? {
        let devs = cameraDevices()
        if let id = cameraDeviceID, let d = devs.first(where: { $0.uniqueID == id }) { return d }
        return AVCaptureDevice.default(for: .video) ?? devs.first
    }

    private func showMicMenu(_ b: HoverButton) {
        let menu = NSMenu()
        let off = NSMenuItem(title: NSLocalizedString("Без микрофона", comment: ""), action: #selector(micPick(_:)), keyEquivalent: "")
        off.target = self; off.tag = 0; off.state = mic ? .off : .on
        off.image = menuIcon("mic.slash", selected: !mic)
        menu.addItem(off); menu.addItem(.separator())
        let def = AVCaptureDevice.default(for: .audio)
        for d in micDevices() {
            let it = NSMenuItem(title: d.localizedName, action: #selector(micPick(_:)), keyEquivalent: "")
            it.target = self; it.tag = 1; it.representedObject = d
            let selected = mic && (micDeviceID == d.uniqueID || (micDeviceID == nil && d == def))
            it.state = selected ? .on : .off
            it.image = menuIcon(Self.audioSymbol(for: d.localizedName), selected: selected)
            menu.addItem(it)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.maxY + 4), in: b)
    }
    @objc private func micPick(_ sender: NSMenuItem) {
        if sender.tag == 0 { mic = false }
        else if let d = sender.representedObject as? AVCaptureDevice { mic = true; micDeviceID = d.uniqueID }
        Settings.shared.micEnabled = mic; Settings.shared.micDeviceID = micDeviceID
        refreshMic()
    }

    private func showCameraMenu(_ b: HoverButton) {
        let menu = NSMenu()
        let off = NSMenuItem(title: NSLocalizedString("Без камеры", comment: ""), action: #selector(camPick(_:)), keyEquivalent: "")
        off.target = self; off.tag = 0; off.state = camera ? .off : .on
        off.image = menuIcon("video.slash", selected: !camera)
        menu.addItem(off); menu.addItem(.separator())
        let cams = cameraDevices()
        if cams.isEmpty {
            let none = NSMenuItem(title: NSLocalizedString("Камеры не найдены", comment: ""), action: nil, keyEquivalent: ""); none.isEnabled = false
            menu.addItem(none)
        }
        let defCam = AVCaptureDevice.default(for: .video)
        for d in cams {
            let it = NSMenuItem(title: d.localizedName, action: #selector(camPick(_:)), keyEquivalent: "")
            it.target = self; it.tag = 1; it.representedObject = d
            // Камера по умолчанию (ID не задан) тоже помечается выбранной — как у микрофона.
            let selected = camera && (cameraDeviceID == d.uniqueID || (cameraDeviceID == nil && d == defCam))
            it.state = selected ? .on : .off
            it.image = menuIcon(Self.cameraSymbol(for: d.localizedName), selected: selected)
            menu.addItem(it)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.maxY + 4), in: b)
    }
    @objc private func camPick(_ sender: NSMenuItem) {
        if sender.tag == 0 { camera = false }
        else if let d = sender.representedObject as? AVCaptureDevice { camera = true; cameraDeviceID = d.uniqueID }
        Settings.shared.cameraEnabled = camera; Settings.shared.cameraDeviceID = cameraDeviceID
        refreshCamera()
    }

    private func start() {
        let opts = RecordOptions(mic: mic, micDeviceID: micDeviceID, systemAudio: sys,
                                 camera: camera, cameraDeviceID: cameraDeviceID)
        removeMonitor()
        panel?.orderOut(nil); panel = nil
        onRecord?(opts)
    }
    private func cancel() {
        removeMonitor()
        panel?.orderOut(nil); panel = nil
        onCancel?()
    }
}
