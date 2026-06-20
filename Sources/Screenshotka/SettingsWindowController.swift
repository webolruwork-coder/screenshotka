import AppKit
import Carbon.HIToolbox

/// Нативное окно настроек macOS с системным toolbar и стандартными controls.
final class SettingsWindowController: NSWindowController, NSToolbarDelegate {

    private enum Pane: CaseIterable {
        case general
        case screenshots
        case video
        case shortcuts

        var identifier: NSToolbarItem.Identifier {
            switch self {
            case .general: return .settingsGeneral
            case .screenshots: return .settingsScreenshots
            case .video: return .settingsVideo
            case .shortcuts: return .settingsShortcuts
            }
        }

        var title: String {
            switch self {
            case .general: return NSLocalizedString("Основные", comment: "")
            case .screenshots: return NSLocalizedString("Скриншоты", comment: "")
            case .video: return NSLocalizedString("Видео", comment: "")
            case .shortcuts: return NSLocalizedString("Хоткеи", comment: "")
            }
        }

        var symbolName: String {
            switch self {
            case .general: return "gearshape"
            case .screenshots: return "camera.viewfinder"
            case .video: return "video"
            case .shortcuts: return "keyboard"
            }
        }
    }

    private let toolbar = NSToolbar(identifier: "Screenshotka.SettingsToolbar")
    private let container = NSView()
    private var currentPane: Pane = .general
    private weak var saveFolderLabel: NSTextField?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = NSLocalizedString("Настройки", comment: "")
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .preference
        window.center()
        super.init(window: window)

        configureToolbar()
        buildLayout()
        select(.general)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        select(currentPane)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func configureToolbar() {
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window?.toolbar = toolbar
    }

    private func buildLayout() {
        guard let content = window?.contentView else { return }
        container.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            container.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 32),
            container.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -32),
            container.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
        ])
    }

    private func select(_ pane: Pane) {
        currentPane = pane
        toolbar.selectedItemIdentifier = pane.identifier
        container.subviews.forEach { $0.removeFromSuperview() }

        let view: NSView
        switch pane {
        case .general: view = buildGeneral()
        case .screenshots: view = buildScreenshots()
        case .video: view = buildVideo()
        case .shortcuts: view = buildShortcuts()
        }

        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    @objc private func toolbarItemClicked(_ sender: NSToolbarItem) {
        guard let pane = Pane.allCases.first(where: { $0.identifier == sender.itemIdentifier }) else { return }
        select(pane)
    }

    // MARK: - NSToolbarDelegate

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Pane.allCases.map(\.identifier)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Pane.allCases.map(\.identifier)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Pane.allCases.map(\.identifier)
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let pane = Pane.allCases.first(where: { $0.identifier == itemIdentifier }) else { return nil }

        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = pane.title
        item.paletteLabel = pane.title
        item.toolTip = pane.title
        item.image = NSImage(systemSymbolName: pane.symbolName, accessibilityDescription: pane.title)
        item.target = self
        item.action = #selector(toolbarItemClicked(_:))
        return item
    }

    // MARK: - Pages

    private func buildGeneral() -> NSView {
        let grid = settingsGrid()
        addRow(grid, NSLocalizedString("Язык:", comment: ""), languageControl())
        addRow(grid, NSLocalizedString("Папка снимков:", comment: ""), saveFolderControl())
        addRow(grid, "", hint(NSLocalizedString("Сюда сохраняются снимки экрана и видеозаписи.", comment: "")))
        addRow(grid, NSLocalizedString("Управление:", comment: ""), check(NSLocalizedString("Показывать панель управления при записи", comment: ""),
                                          get: { Settings.shared.showControlsWhileRecording },
                                          set: { Settings.shared.showControlsWhileRecording = $0 }))
        addRow(grid, NSLocalizedString("Меню-бар:", comment: ""), check(NSLocalizedString("Показывать время записи", comment: ""),
                                        get: { Settings.shared.displayRecordingTime },
                                        set: { Settings.shared.displayRecordingTime = $0 }))
        addRow(grid, NSLocalizedString("Система:", comment: ""), launchAtLoginCheck())
        addRow(grid, NSLocalizedString("Уведомления:", comment: ""), disabledCheck(NSLocalizedString("«Не беспокоить» во время записи", comment: ""),
                                                   tip: NSLocalizedString("Системного API для режима «Не беспокоить» нет — пункт недоступен.", comment: "")))
        addRow(grid, NSLocalizedString("Курсор:", comment: ""), check(NSLocalizedString("Показывать курсор", comment: ""),
                                      get: { Settings.shared.showCursorInVideo },
                                      set: { Settings.shared.showCursorInVideo = $0 }))
        addRow(grid, "", disabledCheck(NSLocalizedString("Подсвечивать клики", comment: ""),
                                       tip: NSLocalizedString("Пока не реализовано.", comment: "")))
        addRow(grid, NSLocalizedString("Клавиатура:", comment: ""), disabledCheck(NSLocalizedString("Показывать нажатия клавиш", comment: ""),
                                                  tip: NSLocalizedString("Пока не реализовано.", comment: "")))
        addRow(grid, NSLocalizedString("Область записи:", comment: ""), check(NSLocalizedString("Запоминать последнее выделение", comment: ""),
                                              get: { Settings.shared.rememberLastSelection },
                                              set: { Settings.shared.rememberLastSelection = $0 }))
        addRow(grid, "", check(NSLocalizedString("Затемнять экран во время записи", comment: ""),
                               get: { Settings.shared.dimScreenWhileRecording },
                               set: { Settings.shared.dimScreenWhileRecording = $0 }))
        addRow(grid, "", check(NSLocalizedString("Показывать обратный отсчёт", comment: ""),
                               get: { Settings.shared.showCountdown },
                               set: { Settings.shared.showCountdown = $0 }))
        alignGridLabels(grid)
        return scrollPage(grid)
    }

    private weak var ssQualitySlider: NSSlider?
    private weak var ssQualityValueLabel: NSTextField?
    private weak var ssQualityRow: NSGridRow?
    private weak var ssFormatHint: NSTextField?

    /// Вкладка «Скриншоты»: три секции в стиле системных настроек —
    /// «Файл» (формат/качество), «Съёмка» (что попадает в кадр), «После снимка» (что происходит дальше).
    private func buildScreenshots() -> NSView {
        let grid = settingsGrid()

        // ─── Файл ───
        addSectionRow(grid, NSLocalizedString("Файл", comment: ""))
        let fmtPopup = NSPopUpButton()
        fmtPopup.controlSize = .regular
        for f in ScreenshotFormat.allCases {
            fmtPopup.addItem(withTitle: f.title)
            fmtPopup.lastItem?.representedObject = f.rawValue
        }
        fmtPopup.selectItem(at: ScreenshotFormat.allCases.firstIndex(of: Settings.shared.screenshotFormat) ?? 0)
        fmtPopup.target = self; fmtPopup.action = #selector(ssFormatChanged(_:))
        addRow(grid, NSLocalizedString("Формат:", comment: ""), fmtPopup)

        // Контекстная подсказка — меняется вместе с выбранным форматом.
        let fmtHint = hint("")
        ssFormatHint = fmtHint
        addRow(grid, "", fmtHint)

        // Качество — только для JPEG/HEIF; для PNG строка скрыта целиком.
        let slider = NSSlider(value: Settings.shared.screenshotQuality, minValue: 0.3, maxValue: 1.0,
                              target: self, action: #selector(ssQualityChanged(_:)))
        slider.controlSize = .regular
        slider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        ssQualitySlider = slider
        let qValue = NSTextField(labelWithString: "")
        qValue.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        qValue.textColor = .secondaryLabelColor
        ssQualityValueLabel = qValue
        let qStack = NSStackView(views: [slider, qValue]); qStack.spacing = 8; qStack.alignment = .centerY
        ssQualityRow = addRow(grid, NSLocalizedString("Качество:", comment: ""), qStack)

        // ─── Съёмка ───
        addSectionRow(grid, NSLocalizedString("Съёмка", comment: ""))
        addRow(grid, "", check(NSLocalizedString("Полное Retina-разрешение (2×)", comment: ""),
                               get: { !Settings.shared.screenshotScaleTo1x },
                               set: { Settings.shared.screenshotScaleTo1x = !$0 }))
        addRow(grid, "", hint(NSLocalizedString("Выключите для 1× — файл легче, но на Retina-экране чуть мягче.", comment: "")))
        addRow(grid, "", check(NSLocalizedString("Сохранять тень при съёмке окна", comment: ""),
                               get: { Settings.shared.screenshotWindowShadow },
                               set: { Settings.shared.screenshotWindowShadow = $0 }))
        addRow(grid, "", check(NSLocalizedString("Замораживать экран при выборе области", comment: ""),
                               get: { Settings.shared.freezeScreen },
                               set: { Settings.shared.freezeScreen = $0 }))

        // ─── После снимка ───
        addSectionRow(grid, NSLocalizedString("После снимка", comment: ""))
        addRow(grid, "", check(NSLocalizedString("Показывать превью", comment: ""),
                               get: { Settings.shared.showPreview },
                               set: { Settings.shared.showPreview = $0 }))
        addRow(grid, "", check(NSLocalizedString("Копировать в буфер обмена", comment: ""),
                               get: { Settings.shared.copyToClipboard },
                               set: { Settings.shared.copyToClipboard = $0 }))
        addRow(grid, "", check(NSLocalizedString("Сохранять в папку снимков", comment: ""),
                               get: { Settings.shared.autoSave },
                               set: { Settings.shared.autoSave = $0 }))
        addRow(grid, NSLocalizedString("Папка:", comment: ""), saveFolderControl())
        addRow(grid, "", check(NSLocalizedString("Проигрывать звук затвора", comment: ""),
                               get: { Settings.shared.playSound },
                               set: { Settings.shared.playSound = $0 }))

        alignGridLabels(grid)
        updateSSFormatUI()
        return scrollPage(grid)
    }

    /// Заголовок секции на всю ширину грида (обе колонки слиты, выравнивание влево).
    private func addSectionRow(_ grid: NSGridView, _ title: String) {
        let row = grid.addRow(with: [sectionHeader(title), NSGridCell.emptyContentView])
        row.mergeCells(in: NSRange(location: 0, length: 2))
        row.cell(at: 0).xPlacement = .leading
    }

    @objc private func ssFormatChanged(_ sender: NSPopUpButton) {
        if let raw = sender.selectedItem?.representedObject as? String, let f = ScreenshotFormat(rawValue: raw) {
            Settings.shared.screenshotFormat = f
        }
        updateSSFormatUI()
    }
    @objc private func ssQualityChanged(_ sender: NSSlider) {
        Settings.shared.screenshotQuality = sender.doubleValue
        updateSSFormatUI()
    }
    private func updateSSFormatUI() {
        let fmt = Settings.shared.screenshotFormat
        ssQualityRow?.isHidden = !fmt.isLossy
        ssQualitySlider?.doubleValue = Settings.shared.screenshotQuality
        ssQualityValueLabel?.stringValue = "\(Int((Settings.shared.screenshotQuality * 100).rounded())) %"
        switch fmt {
        case .png:
            ssFormatHint?.stringValue = NSLocalizedString("Максимальное качество без потерь. Лучший выбор по умолчанию.", comment: "")
        case .jpeg:
            ssFormatHint?.stringValue = NSLocalizedString("Файл меньше, но без прозрачности: фон под тенью окна станет белым.", comment: "")
        case .heif:
            ssFormatHint?.stringValue = NSLocalizedString("Современный формат: заметно меньше JPEG при том же качестве, с прозрачностью.", comment: "")
        }
    }

    private func buildVideo() -> NSView {
        let grid = settingsGrid()

        let resPopup = NSPopUpButton()
        resPopup.controlSize = .regular
        let resOptions: [(String, Int)] = [(NSLocalizedString("Оригинал", comment: ""), 0), ("2160p (4K)", 2160), ("1440p", 1440), ("1080p", 1080), ("720p", 720)]
        resOptions.forEach { resPopup.addItem(withTitle: $0.0); resPopup.lastItem?.tag = $0.1 }
        resPopup.selectItem(withTag: Settings.shared.maxVideoHeight)
        resPopup.target = self
        resPopup.action = #selector(resChanged(_:))
        addRow(grid, NSLocalizedString("Макс. разрешение:", comment: ""), resPopup)
        addRow(grid, "", hint(NSLocalizedString("Ограничьте разрешение, чтобы уменьшить размер файла.", comment: "")))

        let fpsPopup = NSPopUpButton()
        fpsPopup.controlSize = .regular
        [60, 30, 24].forEach { fpsPopup.addItem(withTitle: "\($0)"); fpsPopup.lastItem?.tag = $0 }
        fpsPopup.selectItem(withTag: Settings.shared.videoFPS)
        fpsPopup.target = self
        fpsPopup.action = #selector(fpsChanged(_:))
        addRow(grid, NSLocalizedString("Частота кадров:", comment: ""), fpsPopup)

        addRow(grid, "Retina:", check(NSLocalizedString("Масштабировать Retina-видео в 1x", comment: ""),
                                      get: { Settings.shared.scaleRetinaTo1x },
                                      set: { Settings.shared.scaleRetinaTo1x = $0 }))
        addRow(grid, "", hint(NSLocalizedString("По умолчанию запись идёт в полном Retina-разрешении (2×). Включите, чтобы записывать в 1× — файл меньше примерно в 4 раза, но текст на Retina-экране чуть мягче.", comment: "")))

        addRow(grid, NSLocalizedString("Звук:", comment: ""), check(NSLocalizedString("Записывать звук в моно", comment: ""),
                                    get: { Settings.shared.recordAudioMono },
                                    set: { Settings.shared.recordAudioMono = $0 }))
        addRow(grid, NSLocalizedString("После записи:", comment: ""), check(NSLocalizedString("Открывать редактор после записи", comment: ""),
                                            get: { Settings.shared.openAfterRecording },
                                            set: { Settings.shared.openAfterRecording = $0 }))
        alignGridLabels(grid)
        return scrollPage(grid)
    }

    private func buildShortcuts() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(hint(NSLocalizedString("Кликните по сочетанию справа, затем нажмите новую комбинацию. Esc — отмена, Delete — очистка.", comment: "")))
        stack.addArrangedSubview(sectionHeader(NSLocalizedString("Скриншоты", comment: "")))
        addShortcutRows(to: stack, actions: [.captureArea, .captureAreaCopy, .captureAreaSave, .captureAreaAnnotate, .captureAreaPin, .captureWindow, .captureFullscreen])
        stack.addArrangedSubview(sectionHeader(NSLocalizedString("Запись экрана", comment: "")))
        addShortcutRows(to: stack, actions: [.recordVideo, .recordVideoCopy])

        let reset = NSButton(title: NSLocalizedString("Сбросить хоткеи", comment: ""), target: self, action: #selector(resetHotkeys))
        reset.bezelStyle = .rounded
        reset.controlSize = .regular
        reset.font = .systemFont(ofSize: 13)
        reset.setContentHuggingPriority(.required, for: .horizontal)
        let resetRow = alignedTrailing(reset, top: 18)
        stack.addArrangedSubview(resetRow)

        return scrollPage(stack)
    }

    // MARK: - Save folder

    private func saveFolderControl() -> NSView {
        let path = NSTextField(labelWithString: (Settings.shared.saveFolder.path as NSString).abbreviatingWithTildeInPath)
        path.font = .systemFont(ofSize: 12)
        path.textColor = .secondaryLabelColor
        path.lineBreakMode = .byTruncatingMiddle
        path.cell?.lineBreakMode = .byTruncatingMiddle
        path.toolTip = Settings.shared.saveFolder.path
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        path.setContentHuggingPriority(.defaultLow, for: .horizontal)
        path.widthAnchor.constraint(lessThanOrEqualToConstant: 300).isActive = true
        saveFolderLabel = path

        let change = NSButton(title: NSLocalizedString("Изменить…", comment: ""), target: self, action: #selector(changeSaveFolder))
        change.bezelStyle = .rounded; change.controlSize = .regular; change.font = .systemFont(ofSize: 13)
        change.setContentHuggingPriority(.required, for: .horizontal)

        let reveal = NSButton(title: NSLocalizedString("Открыть", comment: ""), target: self, action: #selector(revealSaveFolder))
        reveal.bezelStyle = .rounded; reveal.controlSize = .regular; reveal.font = .systemFont(ofSize: 13)
        reveal.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: [path, change, reveal])
        stack.orientation = .horizontal; stack.spacing = 8; stack.alignment = .firstBaseline
        return stack
    }

    @objc private func changeSaveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = NSLocalizedString("Выбрать", comment: "")
        panel.message = NSLocalizedString("Куда сохранять снимки и видео", comment: "")
        panel.directoryURL = Settings.shared.saveFolder
        if panel.runModal() == .OK, let url = panel.url {
            Settings.shared.setSaveFolder(url)
            saveFolderLabel?.stringValue = (url.path as NSString).abbreviatingWithTildeInPath
            saveFolderLabel?.toolTip = url.path
        }
    }

    @objc private func revealSaveFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([Settings.shared.saveFolder])
    }

    // MARK: - Language

    /// Порядок совпадает с languageChanged: [Системный, Русский, English, Español].
    private let languageCodes: [String?] = [nil, "ru", "en", "es"]

    private func languageControl() -> NSView {
        let popup = NSPopUpButton()
        popup.controlSize = .regular
        [NSLocalizedString("Системный", comment: ""), "Русский", "English", "Español"]
            .forEach { popup.addItem(withTitle: $0) }
        // Текущий выбор: переопределение AppleLanguages в домене приложения.
        // Его пишет и встроенный переключатель, и системные «Язык и регион → приложения».
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let override = (UserDefaults.standard.persistentDomain(forName: bundleID)?["AppleLanguages"] as? [String])?.first
        let cur = override.map { String($0.prefix(2)) }
        popup.selectItem(at: languageCodes.firstIndex(where: { $0 == cur }) ?? 0)
        popup.target = self
        popup.action = #selector(languageChanged(_:))
        return popup
    }

    @objc private func languageChanged(_ sender: NSPopUpButton) {
        let choice = languageCodes[sender.indexOfSelectedItem]
        if let choice {
            UserDefaults.standard.set([choice], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")   // вернуться к языку системы
        }
        UserDefaults.standard.synchronize()

        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Перезапустить для смены языка?", comment: "")
        alert.informativeText = NSLocalizedString("Язык интерфейса применится после перезапуска приложения.", comment: "")
        alert.addButton(withTitle: NSLocalizedString("Перезапустить", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Позже", comment: ""))
        if alert.runModal() == .alertFirstButtonReturn {
            // Надёжный перезапуск: текущий инстанс выходит, отдельный шелл ждёт его
            // завершения и запускает свежий — тот подхватит новый AppleLanguages.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "sleep 0.4; open \"\(Bundle.main.bundlePath)\""]
            try? p.run()
            NSApp.terminate(nil)
        }
    }

    // MARK: - Builders

    private func settingsGrid() -> NSGridView {
        let grid = NSGridView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 14
        grid.columnSpacing = 16
        grid.yPlacement = .center
        return grid
    }

    /// Единая ширина колонки подписей на всех вкладках. Без фиксации NSGridView
    /// растягивает колонку по содержимому конкретной вкладки, и при переключении
    /// вкладок форма «скачет» по горизонтали (split-линия гуляла ~155 ↔ ~222 pt).
    private static let labelColumnWidth: CGFloat = 130

    private func alignGridLabels(_ grid: NSGridView) {
        guard grid.numberOfColumns > 0 else { return }
        let column = grid.column(at: 0)
        column.xPlacement = .trailing
        // max с фактической шириной — страховка для локализаций с длинными подписями:
        // такая вкладка отъедет от общей линии, но текст не обрежется.
        var widest: CGFloat = 0
        for row in 0..<grid.numberOfRows {
            if let label = grid.cell(atColumnIndex: 0, rowIndex: row).contentView as? NSTextField {
                widest = max(widest, label.fittingSize.width)
            }
        }
        column.width = max(widest, Self.labelColumnWidth)
    }

    private func scrollPage(_ documentContent: NSView) -> NSView {
        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(documentContent)
        NSLayoutConstraint.activate([
            documentContent.topAnchor.constraint(equalTo: document.topAnchor),
            documentContent.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            documentContent.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            documentContent.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        // Перевёрнутый clip view: короткий контент прижимается к ВЕРХУ (а не к низу),
        // и при переключении вкладок раскладка не прыгает по вертикали.
        scroll.contentView = FlippedClipView()
        scroll.documentView = document

        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        return scroll
    }

    @discardableResult
    private func addRow(_ grid: NSGridView, _ label: String, _ control: NSView) -> NSGridRow {
        let labelView = NSTextField(labelWithString: label)
        labelView.font = .systemFont(ofSize: 13)
        labelView.textColor = .secondaryLabelColor
        labelView.alignment = .right
        return grid.addRow(with: [labelView, control])
    }

    private func check(_ title: String, get: @escaping () -> Bool, set: @escaping (Bool) -> Void) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        button.controlSize = .regular
        button.state = get() ? .on : .off
        let handler = CheckboxHandler(set: set)
        button.target = handler
        button.action = #selector(CheckboxHandler.toggled(_:))
        objc_setAssociatedObject(button, &CheckboxHandler.key, handler, .OBJC_ASSOCIATION_RETAIN)
        return button
    }

    private func launchAtLoginCheck() -> NSButton {
        let button = NSButton(checkboxWithTitle: NSLocalizedString("Запускать при входе в систему", comment: ""), target: self, action: #selector(toggleLaunchAtLogin(_:)))
        button.controlSize = .regular
        button.state = LaunchAtLoginManager.isEnabled ? .on : .off
        button.toolTip = NSLocalizedString("Создаёт LaunchAgent в ~/Library/LaunchAgents для запуска Скриншотилки при входе в macOS.", comment: "")
        return button
    }

    private func disabledCheck(_ title: String, tip: String) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        button.controlSize = .regular
        button.state = .off
        button.isEnabled = false
        button.toolTip = tip
        return button
    }

    private func hint(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        return label
    }

    private func sectionHeader(_ title: String) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor),
            label.topAnchor.constraint(equalTo: view.topAnchor, constant: 18),
            label.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
        ])
        return view
    }

    private func addShortcutRows(to stack: NSStackView, actions: [HotkeyAction]) {
        for (index, action) in actions.enumerated() {
            stack.addArrangedSubview(shortcutRow(action))
            if index < actions.count - 1 {
                stack.addArrangedSubview(separator())
            }
        }
    }

    private func shortcutRow(_ action: HotkeyAction) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: action.title)
        title.font = .systemFont(ofSize: 13)
        title.textColor = .labelColor
        title.translatesAutoresizingMaskIntoConstraints = false

        let recorder = ShortcutRecorderButton(action: action)
        recorder.translatesAutoresizingMaskIntoConstraints = false

        // Крестик сброса справа от сочетания.
        let clear = NSButton(title: "", target: recorder, action: #selector(ShortcutRecorderButton.clearHotkey))
        clear.isBordered = false
        clear.bezelStyle = .regularSquare
        clear.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: NSLocalizedString("Сбросить хоткей", comment: ""))?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
        clear.contentTintColor = .tertiaryLabelColor
        clear.toolTip = NSLocalizedString("Сбросить хоткей", comment: "")
        clear.setAccessibilityLabel(NSLocalizedString("Сбросить хоткей", comment: ""))
        clear.translatesAutoresizingMaskIntoConstraints = false

        row.addSubview(title)
        row.addSubview(recorder)
        row.addSubview(clear)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 42),
            title.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            title.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            recorder.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 20),
            recorder.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            recorder.widthAnchor.constraint(equalToConstant: 190),
            recorder.heightAnchor.constraint(equalToConstant: 30),
            clear.leadingAnchor.constraint(equalTo: recorder.trailingAnchor, constant: 6),
            clear.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            clear.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            clear.widthAnchor.constraint(equalToConstant: 22),
            clear.heightAnchor.constraint(equalToConstant: 22),
        ])
        return row
    }

    private func separator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return separator
    }

    private func alignedTrailing(_ view: NSView, top: CGFloat) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        view.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: row.topAnchor, constant: top),
            view.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ])
        return row
    }

    @objc private func resChanged(_ sender: NSPopUpButton) { Settings.shared.maxVideoHeight = sender.selectedTag() }
    @objc private func fpsChanged(_ sender: NSPopUpButton) { Settings.shared.videoFPS = sender.selectedTag() }

    @objc private func resetHotkeys() {
        Settings.shared.resetHotkeys()
        select(.shortcuts)
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSButton) {
        let enabled = sender.state == .on
        do {
            try LaunchAtLoginManager.setEnabled(enabled)
            sender.state = LaunchAtLoginManager.isEnabled ? .on : .off
        } catch {
            sender.state = LaunchAtLoginManager.isEnabled ? .on : .off
            let alert = NSAlert(error: error)
            alert.messageText = NSLocalizedString("Не удалось изменить автозапуск", comment: "")
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

/// Перевёрнутый clip view: контент в NSScrollView выравнивается по ВЕРХУ,
/// а не по низу (поведение NSClipView по умолчанию для короткого документа).
private final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

private extension NSToolbarItem.Identifier {
    static let settingsGeneral = NSToolbarItem.Identifier("Screenshotka.Settings.General")
    static let settingsScreenshots = NSToolbarItem.Identifier("Screenshotka.Settings.Screenshots")
    static let settingsVideo = NSToolbarItem.Identifier("Screenshotka.Settings.Video")
    static let settingsShortcuts = NSToolbarItem.Identifier("Screenshotka.Settings.Shortcuts")
}

/// Хранит замыкание для чекбокса (NSButton требует target/action).
private final class CheckboxHandler: NSObject {
    static var key: UInt8 = 0
    let set: (Bool) -> Void
    init(set: @escaping (Bool) -> Void) { self.set = set }
    @objc func toggled(_ sender: NSButton) { set(sender.state == .on) }
}

private final class ShortcutRecorderButton: NSButton {
    private let hotkeyAction: HotkeyAction
    private var recording = false

    init(action: HotkeyAction) {
        self.hotkeyAction = action
        super.init(frame: .zero)
        bezelStyle = .rounded
        controlSize = .regular
        isBordered = true
        focusRingType = .default
        font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        setButtonType(.momentaryPushIn)
        target = self
        self.action = #selector(startRecording)
        toolTip = NSLocalizedString("Кликните и нажмите новое сочетание. Esc — отмена, Delete — очистка.", comment: "")
        updateTitle()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    // Потеря фокуса (клик мимо, смена вкладки) — выходим из режима записи,
    // иначе кнопка навсегда зависает в «Нажмите сочетание…» и позже ловит случайные клавиши.
    override func resignFirstResponder() -> Bool {
        if recording {
            recording = false
            updateTitle()
        }
        return super.resignFirstResponder()
    }

    @objc private func startRecording() {
        recording = true
        window?.makeFirstResponder(self)
        setDisplayTitle(NSLocalizedString("Нажмите сочетание…", comment: ""), color: .controlAccentColor, font: .systemFont(ofSize: 13, weight: .medium))
    }

    /// Сброс хоткея (крестик справа от сочетания).
    @objc func clearHotkey() {
        recording = false
        Settings.shared.setHotkey(HotkeyShortcut(keyCode: 0, modifiers: 0), for: hotkeyAction)
        updateTitle()
    }

    override func keyDown(with event: NSEvent) {
        guard recording else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == kVK_Escape {
            recording = false
            updateTitle()
            return
        }
        if event.keyCode == kVK_Delete || event.keyCode == kVK_ForwardDelete {
            Settings.shared.setHotkey(HotkeyShortcut(keyCode: 0, modifiers: 0), for: hotkeyAction)
            recording = false
            updateTitle()
            return
        }
        guard let shortcut = HotkeyShortcut.from(event: event), shortcut.isUsable else {
            NSSound.beep()
            return
        }
        if let conflict = HotkeyAction.allCases.first(where: {
            $0 != hotkeyAction && Settings.shared.hotkey(for: $0) == shortcut
        }) {
            showTemporaryMessage(String(format: NSLocalizedString("Занято: %@", comment: ""), conflict.title), color: .systemRed)
            NSSound.beep()
            return
        }
        let current = Settings.shared.hotkey(for: hotkeyAction)
        guard shortcut == current || Self.canRegister(shortcut) else {
            showTemporaryMessage(NSLocalizedString("Недоступно", comment: ""), color: .systemRed)
            NSSound.beep()
            return
        }
        Settings.shared.setHotkey(shortcut, for: hotkeyAction)
        recording = false
        updateTitle(success: true)
    }

    private func updateTitle(success: Bool = false) {
        let shortcut = Settings.shared.hotkey(for: hotkeyAction)
        let text = success ? "✓  \(shortcut.displayString)" : shortcut.displayString
        setDisplayTitle(text, color: success ? .systemGreen : .labelColor, font: .monospacedSystemFont(ofSize: 13, weight: .medium))
        if success {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in self?.updateTitle() }
        }
    }

    private func showTemporaryMessage(_ text: String, color: NSColor) {
        setDisplayTitle(text, color: color, font: .systemFont(ofSize: 12, weight: .medium))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self, self.recording else { return }
            self.setDisplayTitle(NSLocalizedString("Нажмите сочетание…", comment: ""), color: .controlAccentColor, font: .systemFont(ofSize: 13, weight: .medium))
        }
    }

    private func setDisplayTitle(_ text: String, color: NSColor, font: NSFont) {
        attributedTitle = NSAttributedString(string: text, attributes: [
            .foregroundColor: color,
            .font: font,
        ])
    }

    private static func canRegister(_ shortcut: HotkeyShortcut) -> Bool {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x53534854), id: 9999)
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), UInt32(shortcut.modifiers), hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if let ref { UnregisterEventHotKey(ref) }
        return status == noErr
    }
}
