import AppKit
import AVFoundation
import Sparkle

final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum AreaCapturePurpose {
        case standard
        case copy
        case save
        case annotate
        case pin
    }

    private var statusItem: NSStatusItem!
    private let hotkeys = HotkeyManager()
    private var overlay: SelectionOverlayController?
    private var previews: [PreviewPanel] = []
    private var editors: [EditorWindowController] = []
    private let recorder = ScreenRecorder()
    private var recorderBar: RecorderBarController?
    private var optionsBar: RecordOptionsBar?
    private var cameraBubble: CameraBubble?
    private var dimOverlay: DimOverlay?
    private var settingsWC: SettingsWindowController?
    private var historyPanel: HistoryPanel?
    private var videoEditors: [VideoEditorWindowController] = []
    private var recordSeconds = 0
    private var recordTimer: Timer?
    private var blinkTimer: Timer?   // лёгкое мигание красной иконки во время записи
    private let launchTime = Date()  // для подавления авто-открытия Истории на старте
    /// Текущая запись запущена в режиме «скопировать в буфер + показать плашку в углу».
    private var videoCopyMode = false
    /// «Занято» между подтверждением записи и реальным стартом рекордера
    /// (обратный отсчёт + асинхронный recorder.start) — защита от двойного запуска.
    private var pendingRecording = false
    /// «Занято» во время асинхронного захвата заморозки перед показом оверлея области —
    /// защита от наслоения при быстрых повторных нажатиях хоткея.
    private var pendingAreaCapture = false

    /// Sparkle: авто-обновления. `startingUpdater: true` сразу запускает фоновую проверку
    /// по расписанию (SUScheduledCheckInterval из Info.plist) и валидирует подписи EdDSA.
    /// lazy — чтобы передать `self` делегатом (для диагностического self-test'а).
    private(set) lazy var updaterController = SPUStandardUpdaterController(startingUpdater: true,
                                                                          updaterDelegate: self,
                                                                          userDriverDelegate: nil)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMainMenu()
        setupStatusItem()
        setupHotkeys()
        // Смерть стрима записи (отключили дисплей, система забрала захват):
        // финализированный остаток уже сохранён рекордером — закрываем UI записи и сообщаем.
        recorder.onStopped = { [weak self] url in
            guard let self, self.recorder.state == .idle, self.recorderBar != nil || self.recordTimer != nil else { return }
            self.finishRecording(url)
        }
        recorder.onError = { [weak self] message in
            guard let self else { return }
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Запись прервана", comment: "")
            alert.informativeText = message
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(hotkeysChanged),
                                               name: .screenshotkaHotkeysChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(openSettings),
                                               name: .screenshotkaOpenSettings, object: nil)
        // Заранее просим доступ к записи экрана, чтобы первый снимок не упирался в ошибку.
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }

        // Диагностический self-test обновлений (только когда задан SK_UPDATE_SELFTEST).
        // Тихо проверяет фид без UI и печатает результат — для автоматической верификации.
        if ProcessInfo.processInfo.environment["SK_UPDATE_SELFTEST"] != nil {
            FileHandle.standardError.write(NSLocalizedString("SELFTEST: запуск проверки обновлений…\n", comment: "").data(using: .utf8)!)
            updaterController.updater.checkForUpdateInformation()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Тихий запуск: при автозапуске/логине система шлёт «reopen» сразу после старта —
        // игнорируем его, чтобы История не всплывала сама. Ручной reopen позже работает.
        if Date().timeIntervalSince(launchTime) < 3 { return false }
        openHistory()
        return false
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: NSLocalizedString("Скриншотилка", comment: ""))
            button.image?.isTemplate = true
        }
        let menu = buildMenu()
        menu.delegate = self   // галочки тумблеров обновляются при каждом открытии
        statusItem.menu = menu
    }

    /// Главное меню приложения. У menubar-приложения его обычно нет, из-за чего
    /// стандартные хоткеи (⌘W — закрыть, ⌘C/⌘V/⌘X/⌘A в текстовых полях, ⌘Z) не
    /// работают ни в одном окне. Пункты с nil-target маршрутизируются по цепочке
    /// первого ответчика; если их никто не обрабатывает — пункт гаснет и хоткей
    /// уходит дальше (в performKeyEquivalent вью, напр. в редакторе изображения).
    private func buildMainMenu() -> NSMenu {
        let main = NSMenu()

        // Меню приложения (первый пункт).
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: NSLocalizedString("О программе «Скриншотилка»", comment: ""), action: #selector(about), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: NSLocalizedString("Настройки…", comment: ""), action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: NSLocalizedString("Скрыть", comment: ""), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: NSLocalizedString("Выйти", comment: ""), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        // Файл → Закрыть (⌘W).
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: NSLocalizedString("Файл", comment: ""))
        fileMenu.addItem(withTitle: NSLocalizedString("Закрыть", comment: ""), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        // Правка → стандартные команды редактирования (работают в текстовых полях,
        // в остальных случаях гаснут и пропускают хоткей дальше).
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: NSLocalizedString("Правка", comment: ""))
        editMenu.addItem(withTitle: NSLocalizedString("Отменить", comment: ""), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: NSLocalizedString("Повторить", comment: ""), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: NSLocalizedString("Вырезать", comment: ""), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: NSLocalizedString("Копировать", comment: ""), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: NSLocalizedString("Вставить", comment: ""), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: NSLocalizedString("Выбрать все", comment: ""), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        return main
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        menu.addItem(action(NSLocalizedString("История", comment: ""), "openHistory"))
        menu.addItem(.separator())
        menu.addItem(shortcutAction(NSLocalizedString("Снять область", comment: ""), "captureArea", .captureArea))
        menu.addItem(shortcutAction(NSLocalizedString("Снять окно", comment: ""), "captureWindow", .captureWindow))
        menu.addItem(shortcutAction(NSLocalizedString("Весь экран", comment: ""), "captureFullscreen", .captureFullscreen))
        menu.addItem(action(NSLocalizedString("Прокрутка захвата", comment: ""), "captureScrolling"))
        menu.addItem(shortcutAction(NSLocalizedString("Записать видео", comment: ""), "captureVideo", .recordVideo))

        menu.addItem(.separator())
        menu.addItem(action(NSLocalizedString("Открыть папку снимков", comment: ""), "openFolder"))

        // Настройки — единое подменю: быстрые тумблеры + папка + полное окно настроек.
        let settings = NSMenu()
        settings.addItem(toggle(NSLocalizedString("Копировать в буфер", comment: ""), "toggleCopy", on: Settings.shared.copyToClipboard))
        settings.addItem(toggle(NSLocalizedString("Показывать превью", comment: ""), "togglePreview", on: Settings.shared.showPreview))
        settings.addItem(toggle(NSLocalizedString("Автосохранение", comment: ""), "toggleAutoSave", on: Settings.shared.autoSave))
        settings.addItem(toggle(NSLocalizedString("Заморозка экрана", comment: ""), "toggleFreeze", on: Settings.shared.freezeScreen))
        settings.addItem(.separator())
        settings.addItem(action(NSLocalizedString("Выбрать папку сохранения…", comment: ""), "chooseFolder"))
        settings.addItem(action(NSLocalizedString("Все настройки…", comment: ""), "openSettings"))
        let settingsItem = NSMenuItem(title: NSLocalizedString("Настройки", comment: ""), action: nil, keyEquivalent: "")
        menu.addItem(settingsItem)
        menu.setSubmenu(settings, for: settingsItem)

        menu.addItem(.separator())
        // Sparkle: ручная проверка обновлений. Target — сам контроллер апдейтера,
        // он сам включает/выключает пункт, пока идёт проверка.
        let updates = NSMenuItem(title: NSLocalizedString("Проверить обновления…", comment: ""),
                                 action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                                 keyEquivalent: "")
        updates.target = updaterController
        menu.addItem(updates)
        menu.addItem(action(NSLocalizedString("О программе", comment: ""), "about"))
        let quit = NSMenuItem(title: NSLocalizedString("Выйти", comment: ""), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        return menu
    }

    private func action(_ title: String, _ sel: String, key: String = "", mods: NSEvent.ModifierFlags = []) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: Selector(sel), keyEquivalent: key)
        item.target = self
        item.keyEquivalentModifierMask = mods
        return item
    }

    private func shortcutAction(_ title: String, _ sel: String, _ hotkeyAction: HotkeyAction) -> NSMenuItem {
        // Показываем сочетание только если оно реально назначено. Для пустого хоткея
        // displayString вернул бы плейсхолдер «Записать хоткей» (он для рекордера в
        // Настройках) — в статус-меню это мусор, поэтому оставляем только название.
        let hk = Settings.shared.hotkey(for: hotkeyAction)
        let label = hk.isUsable ? "\(title)    \(hk.displayString)" : title
        return action(label, sel)
    }

    private func toggle(_ title: String, _ sel: String, on: Bool) -> NSMenuItem {
        // Методы-переключатели принимают NSMenuItem → селектор обязан оканчиваться на ":".
        let item = NSMenuItem(title: title, action: Selector(sel + ":"), keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        return item
    }

    // MARK: - Hotkeys

    private func setupHotkeys() {
        hotkeys.unregisterAll()
        registerHotkey(.captureArea) { [weak self] in self?.captureArea() }
        registerHotkey(.captureAreaCopy) { [weak self] in self?.captureAreaCopy() }
        registerHotkey(.captureAreaSave) { [weak self] in self?.captureAreaSave() }
        registerHotkey(.captureAreaAnnotate) { [weak self] in self?.captureAreaAnnotate() }
        registerHotkey(.captureAreaPin) { [weak self] in self?.captureAreaPin() }
        registerHotkey(.captureWindow) { [weak self] in self?.captureWindow() }
        registerHotkey(.captureFullscreen) { [weak self] in self?.captureFullscreen() }
        registerHotkey(.recordVideo) { [weak self] in self?.captureVideo() }
        registerHotkey(.recordVideoCopy) { [weak self] in self?.captureVideoCopy() }
    }

    private func registerHotkey(_ action: HotkeyAction, handler: @escaping () -> Void) {
        let shortcut = Settings.shared.hotkey(for: action)
        guard shortcut.isUsable else { return }
        let ok = hotkeys.register(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, handler: handler)
        if !ok {
            NSLog("Screenshotka: failed to register hotkey %@ (%@)", action.rawValue, shortcut.displayString)
        }
    }

    @objc private func hotkeysChanged() {
        setupHotkeys()
        let menu = buildMenu()
        menu.delegate = self   // галочки тумблеров обновляются при каждом открытии
        statusItem.menu = menu
    }

    // MARK: - Capture flow

    @objc func captureArea() {
        beginAreaCapture(.standard)
    }

    private func captureAreaCopy() {
        beginAreaCapture(.copy)
    }

    private func captureAreaSave() {
        beginAreaCapture(.save)
    }

    private func captureAreaAnnotate() {
        beginAreaCapture(.annotate)
    }

    private func captureAreaPin() {
        beginAreaCapture(.pin)
    }

    private func beginAreaCapture(_ purpose: AreaCapturePurpose) {
        // overlay==nil закрывает повторное нажатие, когда оверлей УЖЕ открыт.
        // pendingAreaCapture закрывает асинхронное окно заморозки (~300мс между нажатием
        // и появлением оверлея): без него каждое повторное нажатие запускало новый захват
        // экрана и оверлеи/кадры наслаивались — «ерунда» при быстрых нажатиях.
        guard overlay == nil, !pendingAreaCapture else { return }
        if Settings.shared.freezeScreen {
            pendingAreaCapture = true
            // Прицел — сразу, как в системной ⌘⇧4: заморозка занимает заметное время,
            // и смена стрелки на прицел после этой паузы читается глазом как «скачок» курсора.
            SelectionView.reticleCursor.set()
            // Заморозка: сначала снимаем все экраны, затем показываем оверлей с «застывшим» кадром.
            Task { [weak self] in
                var frozen: [CGDirectDisplayID: CGImage] = [:]
                for screen in NSScreen.screens {
                    if let id = screen.displayID,
                       // Без курсора: иначе он «вмерзает» в кадр в точке нажатия хоткея.
                       let img = try? await ScreenCapturer.captureFullscreen(screen: screen, showsCursor: false) {
                        frozen[id] = img
                    }
                }
                // Неизменяемая копия — чтобы не захватывать var через границу MainActor (Swift 6).
                let frozenResult = frozen
                await MainActor.run { [weak self] in
                    self?.pendingAreaCapture = false
                    self?.presentAreaOverlay(frozen: frozenResult, purpose: purpose)
                }
            }
        } else {
            presentAreaOverlay(frozen: [:], purpose: purpose)
        }
    }

    private func presentAreaOverlay(frozen: [CGDirectDisplayID: CGImage], purpose: AreaCapturePurpose) {
        guard overlay == nil else { return }
        let controller = SelectionOverlayController()
        overlay = controller
        controller.present(mode: .area, frozen: frozen) { [weak self] result in
            self?.overlay = nil
            switch result {
            case .image(let cg, let scale):
                self?.handleAreaCaptured(cg, purpose: purpose, scale: scale)   // заморозка — кадр готов
            case .area(let rect, let screen):
                Task { [weak self] in await self?.performAreaCapture(rect: rect, screen: screen, purpose: purpose) }
            default:
                break
            }
        }
    }

    @objc func captureWindow() {
        guard overlay == nil else { return }
        let controller = SelectionOverlayController()
        overlay = controller
        controller.present(mode: .window) { [weak self] result in
            self?.overlay = nil
            guard case let .window(id) = result else { return }
            Task { [weak self] in await self?.performWindowCapture(id) }
        }
    }

    @objc func captureFullscreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let screen else { return }
        Task { await performFullscreenCapture(screen: screen) }
    }

    /// Прокрутка захвата: длинный снимок прокручиваемого окна.
    @objc func captureScrolling() {
        guard overlay == nil else { return }
        // Синтетический скролл требует доступ «Универсальный доступ» (Accessibility).
        if !ScrollingCapture.isTrusted() {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Нужен доступ «Универсальный доступ»", comment: "")
            alert.informativeText = NSLocalizedString("Для прокрутки захвата разрешите приложению управление в Системных настройках → Конфиденциальность и безопасность → Универсальный доступ, затем повторите.", comment: "")
            alert.addButton(withTitle: NSLocalizedString("Открыть настройки", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("Отмена", comment: ""))
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn { ScrollingCapture.requestTrust() }
            return
        }
        let controller = SelectionOverlayController()
        overlay = controller
        controller.present(mode: .window) { [weak self] result in
            self?.overlay = nil
            guard case let .window(id) = result else { return }
            Task { [weak self] in await self?.performScrollingCapture(id) }
        }
    }

    private func performScrollingCapture(_ id: CGWindowID) async {
        guard let frame = ScreenCapturer.onscreenWindows().first(where: { $0.id == id })?.frameCocoa else {
            await MainActor.run { self.handleError(ScreenCapturer.CaptureError.noWindow) }
            return
        }
        do {
            let cg = try await ScrollingCapture.capture(windowID: id, cocoaFrame: frame)
            await MainActor.run { self.handleCaptured(cg) }
        } catch {
            await MainActor.run { self.handleError(error) }
        }
    }

    // MARK: - Запись видео

    @objc func captureVideo() { beginVideoCapture(copyMode: false) }

    /// Записать видео и по окончании сразу скопировать файл в буфер + показать плашку в углу.
    private func captureVideoCopy() { beginVideoCapture(copyMode: true) }

    private func beginVideoCapture(copyMode: Bool) {
        // Повторное нажатие во время записи — остановка (особенно если панель управления скрыта).
        if recorder.state != .idle { stopRecording(); return }
        guard overlay == nil, recorderBar == nil, optionsBar == nil, !pendingRecording else { return }
        videoCopyMode = copyMode

        // «Запоминать последнее выделение» — пропускаем выбор области.
        if Settings.shared.rememberLastSelection, let r = Settings.shared.lastVideoRect,
           let screen = NSScreen.screens.first(where: { $0.frame.intersects(r) }) {
            showRecordOptions(rect: r, screen: screen)
            return
        }
        let controller = SelectionOverlayController()
        overlay = controller
        controller.present(mode: .video) { [weak self] result in
            self?.overlay = nil
            guard case let .videoArea(rect, screen) = result else { return }
            self?.showRecordOptions(rect: rect, screen: screen)
        }
    }

    private func stopRecording() {
        if let bar = recorderBar { bar.requestStop() }
        else { Task { [weak self] in let url = await self?.recorder.stop(); await MainActor.run { [weak self] in self?.finishRecording(url) } } }
    }

    private func showRecordOptions(rect: CGRect, screen: NSScreen) {
        // Подсвечиваем выбранную область уже на этапе панели опций, чтобы было видно,
        // что именно будет записано (затемнение исключается из захвата).
        dimOverlay?.close()
        dimOverlay = DimOverlay(hole: rect)

        let bar = RecordOptionsBar(near: rect)
        optionsBar = bar
        bar.onCancel = { [weak self] in
            self?.optionsBar = nil
            self?.dimOverlay?.close(); self?.dimOverlay = nil
        }
        bar.onRecord = { [weak self] opts in
            self?.optionsBar = nil
            self?.beginRecording(rect: rect, screen: screen, opts: opts)
        }
    }

    private func beginRecording(rect: CGRect, screen: NSScreen, opts: RecordOptions) {
        Settings.shared.lastVideoRect = rect
        // «Занято» на время отсчёта и асинхронного старта: иначе повторный хоткей
        // в этом окне открывал бы второй выбор области и второй recorder.start.
        pendingRecording = true
        // Обратный отсчёт перед стартом (по настройке).
        if Settings.shared.showCountdown {
            CountdownOverlay.run(on: screen, from: 3) { [weak self] in
                self?.startRecording(rect: rect, screen: screen, opts: opts)
            }
        } else {
            startRecording(rect: rect, screen: screen, opts: opts)
        }
    }

    private func startRecording(rect: CGRect, screen: NSScreen, opts: RecordOptions) {
        Task { [weak self] in
            guard let self else { return }
            // Неизменяемая копия результата запроса доступа (не var через границу MainActor — Swift 6).
            let micGranted = opts.mic ? await self.requestMicAccess() : false

            // Камера: спросить доступ, создать пузырь и включить его окно в запись.
            var exceptingWindow: Int? = nil
            if opts.camera, await self.requestCameraAccess() {
                let bubble = await MainActor.run { CameraBubble(deviceID: opts.cameraDeviceID, near: rect) }
                if let bubble {
                    await MainActor.run { self.cameraBubble = bubble }
                    await bubble.start()
                    exceptingWindow = bubble.windowNumber
                }
            }
            do {
                try await self.recorder.start(rect: rect, screen: screen, mic: micGranted,
                                              systemAudio: opts.systemAudio, fps: Settings.shared.videoFPS,
                                              micDeviceID: opts.micDeviceID, exceptingWindowNumber: exceptingWindow)
                await MainActor.run {
                    self.pendingRecording = false
                    self.showRecorderBar(rect: rect)
                    if opts.mic && !micGranted { self.notifyMicDenied() }
                }
            } catch {
                await MainActor.run {
                    self.pendingRecording = false
                    self.cameraBubble?.stop(); self.cameraBubble = nil
                    self.dimOverlay?.close(); self.dimOverlay = nil
                    self.handleError(error)
                }
            }
        }
    }

    private func requestCameraAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    private func notifyMicDenied() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Доступ к микрофону запрещён", comment: "")
        alert.informativeText = NSLocalizedString("Запись идёт без звука с микрофона. Разрешить можно в Системных настройках → Конфиденциальность и безопасность → Микрофон.", comment: "")
        alert.addButton(withTitle: NSLocalizedString("Открыть настройки", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Продолжить", comment: ""))
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func requestMicAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    private func showRecorderBar(rect: CGRect) {
        updateStatusIcon(recording: true)
        // Подсказка на иконке в меню-баре — особенно полезна, когда панель управления скрыта.
        statusItem.button?.toolTip = NSLocalizedString("Идёт запись · ⌃⇧6 — остановить", comment: "")
        if Settings.shared.displayRecordingTime { startRecordTimer() }

        // Затемнение экрана вокруг области записи (окно приложения исключается из захвата).
        // Подсветка уже могла быть показана на этапе панели опций — продолжаем её
        // показывать при записи, если включено, иначе убираем.
        if Settings.shared.dimScreenWhileRecording {
            if dimOverlay == nil { dimOverlay = DimOverlay(hole: rect) }
        } else {
            dimOverlay?.close(); dimOverlay = nil
        }

        if Settings.shared.showControlsWhileRecording {
            let bar = RecorderBarController(recorder: recorder)
            recorderBar = bar
            bar.onFinished = { [weak self] url in self?.finishRecording(url) }
        }
        // Если панель скрыта — остановка по ⌃⇧6 или клику по иконке в меню-баре.
    }

    private func finishRecording(_ url: URL?) {
        pendingRecording = false
        recorderBar = nil
        cameraBubble?.stop(); cameraBubble = nil
        dimOverlay?.close(); dimOverlay = nil
        recordTimer?.invalidate(); recordTimer = nil
        recordSeconds = 0
        updateStatusIcon(recording: false)
        statusItem.button?.title = ""
        statusItem.button?.toolTip = nil
        let copyMode = videoCopyMode
        videoCopyMode = false
        guard let url else { return }
        if copyMode {
            ImageStore.copyFileToClipboard(url)
            showVideoCopyPreview(url)
            return
        }
        if Settings.shared.openAfterRecording {
            openVideoEditor(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// Плашка в углу экрана после записи в режиме «и скопировать»: миниатюра видео,
    /// перетаскивание отдаёт сам файл, клик открывает видеоредактор. Файл уже в буфере.
    private func showVideoCopyPreview(_ url: URL) {
        Task.detached { [weak self] in   // copyCGImage блокирует — не держим главный поток
            let thumb = Self.videoThumbnail(url: url)
            let duration = await Self.videoDuration(url: url)
            await MainActor.run { [weak self] in
                guard let self else { return }
                let cg = thumb ?? Self.placeholderThumbnail()
                let panel = PreviewPanel(image: cg, dragURL: url, videoDuration: duration)
                panel.onCopy = { ImageStore.copyFileToClipboard(url) }
                panel.onSave = { ImageStore.saveVideoWithDialog(url) }
                panel.onAnnotate = { [weak self, weak panel] in
                    panel?.dismissAnimated { self?.openVideoEditor(url) }
                    if let panel { self?.previews.removeAll { $0 == panel } }
                }
                self.previews.append(panel)
                // Сразу показываем состояние «скопировано» — файл уже в буфере обмена.
                panel.showCopiedAndDismiss { [weak self, weak panel] in
                    if let panel { self?.previews.removeAll { $0 == panel } }
                }
            }
        }
    }

    /// Первый кадр записи как миниатюра для плашки. Выполняется вне MainActor.
    nonisolated private static func videoThumbnail(url: URL) -> CGImage? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 448, height: 296)
        if let cg = try? gen.copyCGImage(at: CMTime(seconds: 0.1, preferredTimescale: 600), actualTime: nil) {
            return cg
        }
        return try? gen.copyCGImage(at: .zero, actualTime: nil)
    }

    /// Длительность записи в секундах (для бейджа на плашке). Современный async-API
    /// (старый синхронный .duration устарел на macOS 15+).
    nonisolated private static func videoDuration(url: URL) async -> Double {
        let dur = (try? await AVURLAsset(url: url).load(.duration)) ?? .zero
        return CMTimeGetSeconds(dur)
    }

    /// Запасная тёмная миниатюра, если кадр получить не удалось.
    nonisolated private static func placeholderThumbnail() -> CGImage {
        let w = 224, h = 148
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.12, green: 0.12, blue: 0.13, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    private func openVideoEditor(_ url: URL) {
        let editor = VideoEditorWindowController(url: url)
        editor.onClose = { [weak self, weak editor] _ in
            if let editor { self?.videoEditors.removeAll { $0 == editor } }
        }
        videoEditors.append(editor)
        editor.present()
    }

    private func startRecordTimer() {
        recordSeconds = 0
        recordTimer?.invalidate()
        recordTimer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, self.recorder.state == .recording else { return }
            self.recordSeconds += 1
            let m = self.recordSeconds / 60, s = self.recordSeconds % 60
            self.statusItem.button?.title = String(format: " %d:%02d", m, s)
        }
        if let t = recordTimer { RunLoop.main.add(t, forMode: .common) }   // тикает и при открытом меню/перетаскивании
    }

    private func updateStatusIcon(recording: Bool) {
        guard let button = statusItem.button else { return }
        blinkTimer?.invalidate(); blinkTimer = nil
        button.alphaValue = 1

        if recording {
            // НЕ template: иначе меню-бар перекрашивает иконку в монохром и игнорирует красный.
            // Палитра systemRed рисует символ красным независимо от темы меню-бара.
            let cfg = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
            let image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: NSLocalizedString("Идёт запись", comment: ""))?
                .withSymbolConfiguration(cfg)
            image?.isTemplate = false
            button.image = image
            button.contentTintColor = nil
            startBlink()
        } else {
            let image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: NSLocalizedString("Скриншотилка", comment: ""))
            image?.isTemplate = true
            button.image = image
            button.contentTintColor = nil
        }
    }

    /// Лёгкое мигание индикатора записи (как «идёт съёмка»). Уважает «Уменьшить движение».
    private func startBlink() {
        guard !Theme.reduceMotion, let button = statusItem.button else { return }
        blinkTimer = Timer(timeInterval: 0.65, repeats: true) { [weak self] _ in
            guard let button = self?.statusItem.button else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.32
                button.animator().alphaValue = (button.alphaValue > 0.7) ? 0.45 : 1.0
            }
        }
        if let t = blinkTimer { RunLoop.main.add(t, forMode: .common) }
        _ = button
    }

    private func performAreaCapture(rect: CGRect, screen: NSScreen, purpose: AreaCapturePurpose = .standard) async {
        do {
            let cg = try await ScreenCapturer.capture(rectInScreen: rect, on: screen)
            let scale = screen.backingScaleFactor
            await MainActor.run { self.handleAreaCaptured(cg, purpose: purpose, scale: scale) }
        } catch { await MainActor.run { self.handleError(error) } }
    }

    private func performWindowCapture(_ id: CGWindowID) async {
        do {
            // Масштаб — экрана, на котором реально находится окно (mixed-DPI),
            // а не NSScreen.main: иначе опция «1×» уменьшала бы не тот кадр.
            let windowFrame = ScreenCapturer.onscreenWindows().first { $0.id == id }?.frameCocoa
            let screen = windowFrame.flatMap { f in
                NSScreen.screens.max { a, b in
                    let ia = a.frame.intersection(f), ib = b.frame.intersection(f)
                    return ia.width * ia.height < ib.width * ib.height
                }
            }
            let scale = screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            let cg = try await ScreenCapturer.capture(windowID: id)
            await MainActor.run { self.handleCaptured(cg, scale: scale) }
        } catch { await MainActor.run { self.handleError(error) } }
    }

    private func performFullscreenCapture(screen: NSScreen) async {
        do {
            let cg = try await ScreenCapturer.captureFullscreen(screen: screen)
            let scale = screen.backingScaleFactor
            await MainActor.run { self.handleCaptured(cg, scale: scale) }
        } catch { await MainActor.run { self.handleError(error) } }
    }

    private func handleCaptured(_ cg: CGImage, scale: CGFloat = 2) {
        playShutter()
        if Settings.shared.copyToClipboard { ImageStore.copyToClipboard(cg) }
        if Settings.shared.autoSave {
            // Кодирование (особенно HEIC на больших Retina-кадрах) — не на главном потоке,
            // иначе UI подвисает после каждого снимка. Превью показываем после записи,
            // чтобы drag из превью отдавал уже готовый файл.
            Task.detached(priority: .userInitiated) { [weak self] in
                let url = ImageStore.saveToDefaultFolder(cg, scale: scale)
                await MainActor.run { [weak self] in
                    guard let self, Settings.shared.showPreview else { return }
                    self.showPreview(cg, scale: scale, dragURL: url)
                }
            }
        } else if Settings.shared.showPreview {
            showPreview(cg, scale: scale)
        }
    }

    private func handleAreaCaptured(_ cg: CGImage, purpose: AreaCapturePurpose, scale: CGFloat = 2) {
        switch purpose {
        case .standard:
            handleCaptured(cg, scale: scale)   // звук уже внутри
        case .copy:
            playShutter()
            ImageStore.copyToClipboard(cg)
            showCopyConfirmation(cg, scale: scale)
        case .save:
            playShutter()
            Task.detached(priority: .userInitiated) {
                ImageStore.saveToDefaultFolder(cg, scale: scale)
            }
        case .annotate:
            playShutter()
            openEditor(cg, scale: scale)
        case .pin:
            playShutter()
            showPreview(cg, scale: scale, pinned: true)
        }
    }

    /// Звук затвора (системный Grab.aif) — по настройке. Загружаем один раз.
    private static let shutterSound: NSSound? = {
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Grab.aif"
        return NSSound(contentsOfFile: path, byReference: true)
    }()
    private func playShutter() {
        guard Settings.shared.playSound, let s = AppDelegate.shutterSound else { return }
        s.stop(); s.play()
    }

    private func showPreview(_ cg: CGImage, scale: CGFloat = 2, pinned: Bool = false, dragURL: URL? = nil) {
        let panel = PreviewPanel(image: cg, initiallyPinned: pinned, dragURL: dragURL)
        panel.onCopy = { ImageStore.copyToClipboard(cg) }
        panel.onSave = { ImageStore.saveWithDialog(cg, scale: scale) }
        panel.onAnnotate = { [weak self, weak panel] in
            panel?.dismissAnimated { self?.openEditor(cg, scale: scale) }
            if let panel { self?.previews.removeAll { $0 == panel } }
        }
        panel.onClose = { [weak self, weak panel] in
            panel?.dismissAnimated { if let panel { self?.previews.removeAll { $0 == panel } } }
        }
        previews.append(panel)
    }

    private func showCopyConfirmation(_ cg: CGImage, scale: CGFloat = 2, force: Bool = false) {
        guard force || Settings.shared.showPreview else { return }
        let panel = PreviewPanel(image: cg)
        // Окно живёт ~6 c — кнопки должны работать (раньше при 0.7 c было незаметно).
        panel.onCopy = { ImageStore.copyToClipboard(cg) }
        panel.onSave = { ImageStore.saveWithDialog(cg, scale: scale) }
        panel.onAnnotate = { [weak self, weak panel] in
            panel?.dismissAnimated { self?.openEditor(cg, scale: scale) }
            if let panel { self?.previews.removeAll { $0 == panel } }
        }
        previews.append(panel)
        panel.showCopiedAndDismiss { [weak self, weak panel] in
            if let panel { self?.previews.removeAll { $0 == panel } }
        }
    }

    private func openEditor(_ cg: CGImage, scale: CGFloat = 2) {
        let controller = EditorWindowController(image: cg, scale: scale)
        controller.onClose = { [weak self, weak controller] in
            if let controller { self?.editors.removeAll { $0 == controller } }
        }
        editors.append(controller)
        controller.present()
    }

    @objc func openHistory() {
        if historyPanel == nil {
            let panel = HistoryPanel()
            panel.onCaptureArea = { [weak self] in self?.captureArea() }
            panel.onCaptureWindow = { [weak self] in self?.captureWindow() }
            panel.onCaptureFullscreen = { [weak self] in self?.captureFullscreen() }
            panel.onRecordVideo = { [weak self] in self?.captureVideo() }
            panel.onOpenEditor = { [weak self] cg in self?.openEditor(cg, scale: 1) }   // файл с диска: не даунскейлить повторно
            panel.onOpenVideoEditor = { [weak self] url in self?.openVideoEditor(url) }
            panel.onCopyImage = { [weak self] cg in self?.showCopyConfirmation(cg, scale: 1, force: true) }
            historyPanel = panel
        }
        historyPanel?.show(near: statusItem.button)
    }

    private func handleError(_ error: Error) {
        NSLog("Ошибка захвата: \(error)")
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Не удалось сделать снимок", comment: "")
        alert.informativeText = String(format: NSLocalizedString("Проверьте разрешение на запись экрана в Системных настройках → Конфиденциальность и безопасность → Запись экрана.\n\n%@", comment: ""), error.localizedDescription)
        alert.addButton(withTitle: NSLocalizedString("Открыть настройки", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Отмена", comment: ""))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: - Menu actions

    @objc func openFolder() { NSWorkspace.shared.open(Settings.shared.saveFolder) }

    @objc func openSettings() {
        if settingsWC == nil { settingsWC = SettingsWindowController() }
        settingsWC?.show()
    }

    @objc func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = Settings.shared.saveFolder
        if panel.runModal() == .OK, let url = panel.url { Settings.shared.setSaveFolder(url) }
    }

    @objc func toggleCopy(_ s: NSMenuItem) { Settings.shared.copyToClipboard.toggle(); s.state = Settings.shared.copyToClipboard ? .on : .off }
    @objc func togglePreview(_ s: NSMenuItem) { Settings.shared.showPreview.toggle(); s.state = Settings.shared.showPreview ? .on : .off }
    @objc func toggleAutoSave(_ s: NSMenuItem) { Settings.shared.autoSave.toggle(); s.state = Settings.shared.autoSave ? .on : .off }
    @objc func toggleFreeze(_ s: NSMenuItem) { Settings.shared.freezeScreen.toggle(); s.state = Settings.shared.freezeScreen ? .on : .off }

    @objc func about() {
        // Версия читается из бандла → меняется автоматически с каждым релизом.
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? ""
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Скриншотилка", comment: "")
        alert.informativeText = String(format: NSLocalizedString("Минималистичные снимки экрана с аннотациями.\n\nВерсия %@ (%@)", comment: ""), version, build)
        alert.runModal()
    }
}

// MARK: - Sparkle: делегат апдейтера (+ диагностический self-test)

extension AppDelegate: SPUUpdaterDelegate {
    /// В режиме self-test переопределяем фид на локальный (SK_UPDATE_FEED),
    /// чтобы прогнать сквозную проверку обновления без обращения к GitHub.
    func feedURLString(for updater: SPUUpdater) -> String? {
        ProcessInfo.processInfo.environment["SK_UPDATE_FEED"]
    }

    private var inSelfTest: Bool { ProcessInfo.processInfo.environment["SK_UPDATE_SELFTEST"] != nil }
    private func selftestLog(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        guard inSelfTest else { return }
        selftestLog("SELFTEST_RESULT: FOUND version=\(item.displayVersionString) build=\(item.versionString)")
        exit(0)   // успех: фид прочитан, подпись прошла, апдейт найден
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        guard inSelfTest else { return }
        selftestLog(NSLocalizedString("SELFTEST_RESULT: NO_UPDATE (фид прочитан, но новее текущей версии нет)", comment: ""))
        exit(3)
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        guard inSelfTest else { return }
        selftestLog("SELFTEST_RESULT: ERROR \(error.localizedDescription)")
        exit(2)
    }
}


extension AppDelegate: NSMenuDelegate {
    /// Статус-меню строится при запуске, а настройки могли поменяться в окне Настроек —
    /// пересобираем пункты при каждом открытии, чтобы галочки тумблеров были актуальны.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }
        let fresh = buildMenu()
        let items = fresh.items
        fresh.removeAllItems()                 // открепить от временного меню
        menu.items = items
    }
}
