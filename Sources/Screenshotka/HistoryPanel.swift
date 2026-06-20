import AppKit
import AVFoundation

// MARK: - Data model

enum MediaKind { case screenshot, video }

struct HistoryEntry: Equatable {
    let url: URL
    let kind: MediaKind
    let modDate: Date
    var duration: Double? // секунды, только для video

    static func == (lhs: HistoryEntry, rhs: HistoryEntry) -> Bool { lhs.url == rhs.url }

    static func load(from folder: URL = Settings.shared.saveFolder) -> [HistoryEntry] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: Array(keys),
            options: .skipsHiddenFiles)) ?? []
        return urls
            .compactMap { url -> HistoryEntry? in
                let values = try? url.resourceValues(forKeys: keys)
                guard values?.isRegularFile == true else { return nil }
                let ext = url.pathExtension.lowercased()
                guard let kind = MediaKind(ext: ext) else { return nil }
                let date = values?.contentModificationDate ?? .distantPast
                return HistoryEntry(url: url, kind: kind, modDate: date, duration: nil)
            }
            .sorted { $0.modDate > $1.modDate }
    }

    /// Относительное время на текущем языке: «5 минут назад» / «5 minutes ago» /
    /// «hace 5 minutos». RelativeDateTimeFormatter сам учитывает локаль и плюрализацию.
    var relativeTimestamp: String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: modDate, relativeTo: Date())
    }
}

extension MediaKind {
    init?(ext: String) {
        switch ext {
        case "png", "jpg", "jpeg", "heic": self = .screenshot
        case "mov", "mp4", "m4v": self = .video
        default: return nil
        }
    }
}

// MARK: - Thumbnail cache

actor ThumbnailCache {
    static let shared = ThumbnailCache()

    /// Превью + дата файла (для инвалидации, если файл перезаписали).
    private final class Entry {
        let image: NSImage; let mtime: Date
        init(_ image: NSImage, _ mtime: Date) { self.image = image; self.mtime = mtime }
    }
    /// NSCache: ограничиваем число превью и авто-вытесняем под давлением памяти,
    /// чтобы кэш не рос без предела на больших историях.
    private let cache: NSCache<NSURL, Entry> = {
        let c = NSCache<NSURL, Entry>()
        c.countLimit = 300
        return c
    }()

    func get(_ url: URL, mtime: Date) -> NSImage? {
        guard let e = cache.object(forKey: url as NSURL), e.mtime == mtime else { return nil }
        return e.image
    }
    func set(_ url: URL, mtime: Date, image: NSImage) {
        cache.setObject(Entry(image, mtime), forKey: url as NSURL)
    }
}

// MARK: - HistoryPanel (main window)

final class HistoryPanel: NSPanel {

    // Callbacks
    var onCaptureArea: (() -> Void)?
    var onCaptureWindow: (() -> Void)?
    var onCaptureFullscreen: (() -> Void)?
    var onRecordVideo: (() -> Void)?
    var onOpenEditor: ((CGImage) -> Void)?
    var onOpenVideoEditor: ((URL) -> Void)?
    var onCopyImage: ((CGImage) -> Void)?

    // State
    var allEntries: [HistoryEntry] = []
    var filter: FilterTab = .all
    var selectedIndex: Int? = nil
    private var toastView: ToastView?
    private var reloadGeneration = 0
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?

    // UI
    private let root = NSVisualEffectView()
    private let tabBar = TabBar()
    private let scrollView = NSScrollView()
    private let collectionView = NSCollectionView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let menuButton = HoverButton(title: "", target: nil, action: nil)
    private let captureStack = NSStackView()

    static let windowHeight: CGFloat = 196
    static let cardW: CGFloat = 168
    static let cardH: CGFloat = 124
    static let thumbH: CGFloat = 92
    static let hPad: CGFloat = 16
    static let itemSpacing: CGFloat = 12

    // MARK: Init

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 900, height: Self.windowHeight),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        buildUI()
    }

    override var canBecomeKey: Bool { true }

    // MARK: Show

    func show(near button: NSStatusBarButton?) {
        reload()
        let screen = screenFor(button: button)
        let vf = screen.visibleFrame
        let w = min(vf.width - 32, max(900, vf.width * 0.85))
        setContentSize(NSSize(width: w, height: Self.windowHeight))
        let x = vf.midX - w / 2
        let y = vf.maxY - Self.windowHeight - 8
        setFrameOrigin(NSPoint(x: x, y: y))
        alphaValue = 0
        orderFrontRegardless()
        makeKey()
        installClickMonitors()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Theme.duration(0.15)
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
    }

    // MARK: Dismiss on outside click

    private func installClickMonitors() {
        removeClickMonitors()
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.window !== self { self.close() }
            return event
        }
    }

    private func removeClickMonitors() {
        if let m = globalClickMonitor { NSEvent.removeMonitor(m); globalClickMonitor = nil }
        if let m = localClickMonitor { NSEvent.removeMonitor(m); localClickMonitor = nil }
    }

    override func orderOut(_ sender: Any?) {
        removeClickMonitors()
        super.orderOut(sender)
    }

    override func close() {
        removeClickMonitors()
        super.close()
    }

    // ⌘W из главного меню (performClose:) на безрамочной панели иначе «бибикает».
    override func performClose(_ sender: Any?) {
        close()
    }

    func reload(from folder: URL = Settings.shared.saveFolder) {
        reloadGeneration += 1
        let generation = reloadGeneration
        selectedIndex = nil
        // Перечисление папки (сотни файлов, сетевые диски) — не на главном потоке:
        // раньше каждое открытие панели фризило весь UI на время обхода.
        Task.detached(priority: .userInitiated) { [weak self] in
            let entries = HistoryEntry.load(from: folder)
            await MainActor.run { [weak self] in
                guard let self, self.reloadGeneration == generation else { return }
                self.allEntries = entries
                self.applyFilter()
                self.loadDurationsAsync(generation: generation)
            }
        }
    }

    /// Выбор по клику на карточке: ставит selectedIndex и точечно обновляет визуал
    /// видимых ячеек. Без reloadData() — не трогает превью и позицию скролла.
    func selectIndex(_ index: Int) {
        guard selectedIndex != index else { return }   // повторный клик по тому же — no-op
        selectedIndex = index
        collectionView.selectionIndexPaths = [IndexPath(item: index, section: 0)]
        refreshSelectionVisuals()
    }

    // MARK: Build UI

    private func buildUI() {
        root.autoresizingMask = [.width, .height]
        root.material = .hudWindow
        root.blendingMode = .behindWindow
        root.state = .active
        root.appearance = NSAppearance(named: .darkAqua)
        root.wantsLayer = true
        root.layer?.cornerRadius = 18
        root.layer?.cornerCurve = .continuous
        root.layer?.masksToBounds = true
        contentView = root

        // Постоянная тёмная подложка поверх вибранси: текст и подписи остаются читаемыми
        // независимо от того, что просвечивает позади полупрозрачной панели.
        let backdrop = NSView()
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = NSColor(white: 0.10, alpha: 0.55).cgColor
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(backdrop)
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: root.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])

        // --- Top bar ---
        let topBar = NSView()
        topBar.translatesAutoresizingMaskIntoConstraints = false

        // Tabs
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.onSelect = { [weak self] tab in self?.switchFilter(tab) }

        // "..." menu button
        menuButton.isBordered = false
        menuButton.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: NSLocalizedString("Меню", comment: ""))?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .medium))
        menuButton.imagePosition = .imageOnly
        menuButton.setFrameSize(NSSize(width: 32, height: 32))
        menuButton.wantsLayer = true
        menuButton.layer?.cornerRadius = 7
        menuButton.restingTint = NSColor(white: 0.75, alpha: 1)
        menuButton.hoverTint = .white
        menuButton.hoverBackground = NSColor(white: 1, alpha: 0.12).cgColor
        menuButton.toolTip = NSLocalizedString("Меню", comment: "")
        menuButton.onAction = { [weak self] in self?.showDotMenu() }
        menuButton.translatesAutoresizingMaskIntoConstraints = false

        // Capture buttons
        let capButtons: [(String, String, () -> Void)] = [
            ("selection.pin.in.out", NSLocalizedString("Область", comment: ""), { [weak self] in self?.triggerCapture(.area) }),
            ("macwindow", NSLocalizedString("Окно", comment: ""), { [weak self] in self?.triggerCapture(.window) }),
            ("rectangle.on.rectangle", NSLocalizedString("Экран", comment: ""), { [weak self] in self?.triggerCapture(.fullscreen) }),
            ("record.circle", NSLocalizedString("Видео", comment: ""), { [weak self] in self?.triggerCapture(.video) }),
        ]
        captureStack.orientation = .horizontal
        captureStack.spacing = 4
        captureStack.translatesAutoresizingMaskIntoConstraints = false
        for (sym, tip, action) in capButtons {
            captureStack.addArrangedSubview(captureBtn(sym, tip, action: action))
        }

        topBar.addSubview(tabBar)
        topBar.addSubview(menuButton)
        topBar.addSubview(captureStack)

        NSLayoutConstraint.activate([
            tabBar.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            tabBar.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            menuButton.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -12),
            menuButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            menuButton.widthAnchor.constraint(equalToConstant: 32),
            menuButton.heightAnchor.constraint(equalToConstant: 32),
            captureStack.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 12),
            captureStack.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 52),
        ])

        // --- Collection view ---
        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = NSSize(width: Self.cardW, height: Self.cardH)
        layout.minimumInteritemSpacing = Self.itemSpacing
        layout.minimumLineSpacing = Self.itemSpacing
        layout.sectionInset = NSEdgeInsets(top: 0, left: Self.hPad, bottom: 0, right: Self.hPad)

        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(CardItem.self, forItemWithIdentifier: .init("card"))
        collectionView.isSelectable = true
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = collectionView
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.hasVerticalScroller = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // Empty state
        emptyLabel.font = .systemFont(ofSize: 14)
        emptyLabel.textColor = NSColor(white: 0.55, alpha: 1)
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(topBar)
        root.addSubview(scrollView)
        root.addSubview(emptyLabel)

        topBar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: root.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),

            emptyLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])

        // Resize collection view height to match scroll
        let cvH = Self.windowHeight - 52 - 8 - 12
        NSLayoutConstraint.activate([
            collectionView.heightAnchor.constraint(equalToConstant: cvH),
        ])
    }

    // MARK: Filter

    private func switchFilter(_ tab: FilterTab) {
        filter = tab
        selectedIndex = nil
        applyFilter()
    }

    private func applyFilter() {
        // Update collection and empty state
        clampSelection()
        collectionView.reloadData()
        collectionView.collectionViewLayout?.invalidateLayout()
        let count = filtered().count
        emptyLabel.isHidden = count > 0
        if count == 0 {
            emptyLabel.stringValue = emptyText()
        }
        collectionView.isHidden = count == 0
    }

    private func clampSelection() {
        let count = filtered().count
        guard count > 0 else {
            selectedIndex = nil
            collectionView.deselectAll(nil)
            return
        }
        if let selectedIndex, selectedIndex >= count {
            self.selectedIndex = count - 1
        }
    }

    func filtered() -> [HistoryEntry] {
        switch filter {
        case .all: return allEntries
        case .screenshots: return allEntries.filter { $0.kind == .screenshot }
        case .videos: return allEntries.filter { $0.kind == .video }
        }
    }

    private func emptyText() -> String {
        switch filter {
        case .all: return NSLocalizedString("Нет снимков или записей\nНажмите ⌃⇧4 чтобы сделать первый снимок", comment: "")
        case .screenshots: return NSLocalizedString("Нет скриншотов", comment: "")
        case .videos: return NSLocalizedString("Нет видеозаписей", comment: "")
        }
    }

    // MARK: Async thumbnails + durations

    private func loadDurationsAsync(generation: Int) {
        let entries = allEntries.filter { $0.kind == .video && $0.duration == nil }.prefix(100)
        for entry in entries {
            Task.detached(priority: .utility) { [weak self] in
                let asset = AVURLAsset(url: entry.url)
                let dur: Double
                if let t = try? await asset.load(.duration) {
                    dur = CMTimeGetSeconds(t)
                } else {
                    dur = 0
                }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    guard self.reloadGeneration == generation else { return }
                    if let idx = self.allEntries.firstIndex(of: entry) {
                        self.allEntries[idx].duration = dur
                        // Reload just that item if visible
                        let filtered = self.filtered()
                        if let fi = filtered.firstIndex(of: self.allEntries[idx]) {
                            let ip = IndexPath(item: fi, section: 0)
                            if fi < self.collectionView.numberOfItems(inSection: 0) {
                                self.collectionView.reloadItems(at: [ip])
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Actions on card

    func openEntry(_ entry: HistoryEntry) {
        switch entry.kind {
        case .screenshot:
            guard let cg = ImageStore.cgImage(from: entry.url) else { return }
            orderOut(nil)
            onOpenEditor?(cg)
        case .video:
            orderOut(nil)
            onOpenVideoEditor?(entry.url)
        }
    }

    func restoreEntry(_ entry: HistoryEntry) {
        switch entry.kind {
        case .screenshot:
            guard let cg = ImageStore.cgImage(from: entry.url) else { return }
            ImageStore.copyToClipboard(cg)
            orderOut(nil)
            onCopyImage?(cg)
        case .video:
            ImageStore.copyFileToClipboard(entry.url)
            showToast(NSLocalizedString("Файл скопирован в буфер", comment: ""))
        }
    }

    func copyEntry(_ entry: HistoryEntry) {
        restoreEntry(entry)
    }

    func showInFinder(_ entry: HistoryEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([entry.url])
    }

    func deleteEntry(_ entry: HistoryEntry) {
        let name = entry.url.lastPathComponent
        do {
            try FileManager.default.trashItem(at: entry.url, resultingItemURL: nil)
            allEntries.removeAll { $0 == entry }
            applyFilter()
            showToast(String(format: NSLocalizedString("«%@» удалён  ·  Нельзя отменить через приложение", comment: ""), name))
        } catch {
            NSLog("Не удалось удалить: \(error)")
        }
    }

    // MARK: Dot-menu

    private func showDotMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: NSLocalizedString("Открыть папку снимков", comment: ""), action: #selector(menuOpenFolder), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        let clear = menu.addItem(withTitle: NSLocalizedString("Очистить историю…", comment: ""), action: #selector(menuClearHistory), keyEquivalent: "")
        clear.target = self
        clear.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        menu.addItem(.separator())
        menu.addItem(withTitle: NSLocalizedString("Настройки…", comment: ""), action: #selector(menuSettings), keyEquivalent: "")
            .target = self
        menu.popUp(positioning: nil, at: NSPoint(x: menuButton.frame.minX, y: menuButton.frame.minY - 4), in: root)
    }

    @objc private func menuOpenFolder() { NSWorkspace.shared.open(Settings.shared.saveFolder) }

    @objc private func menuClearHistory() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Очистить историю?", comment: "")
        alert.informativeText = NSLocalizedString("Все файлы будут перемещены в Корзину. Это действие нельзя отменить через приложение.", comment: "")
        alert.addButton(withTitle: NSLocalizedString("Очистить", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Отмена", comment: ""))
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for entry in allEntries {
            try? FileManager.default.trashItem(at: entry.url, resultingItemURL: nil)
        }
        allEntries = []
        applyFilter()
    }

    @objc private func menuSettings() {
        // Delegate up — AppDelegate should observe this notification
        NotificationCenter.default.post(name: .screenshotkaOpenSettings, object: nil)
    }

    // MARK: Capture triggers

    private enum CaptureKind { case area, window, fullscreen, video }

    private func triggerCapture(_ kind: CaptureKind) {
        orderOut(nil)
        switch kind {
        case .area: onCaptureArea?()
        case .window: onCaptureWindow?()
        case .fullscreen: onCaptureFullscreen?()
        case .video: onRecordVideo?()
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let items = filtered()
        switch event.keyCode {
        case 123: // ←
            let idx = max(0, (selectedIndex ?? 0) - 1)
            setSelection(idx)
        case 124: // →
            let idx = min(items.count - 1, (selectedIndex ?? -1) + 1)
            setSelection(idx)
        case 36, 76: // Enter
            if let i = selectedIndex, i < items.count { openEntry(items[i]) }
        case 51, 117: // Delete / Fwd-Delete
            if let i = selectedIndex, i < items.count { deleteEntry(items[i]) }
        case 53: // Esc
            close()
        default:
            super.keyDown(with: event)
        }
    }

    private func setSelection(_ idx: Int) {
        let items = filtered()
        guard !items.isEmpty else { return }
        let clamped = max(0, min(idx, items.count - 1))
        selectedIndex = clamped
        let ip = IndexPath(item: clamped, section: 0)
        collectionView.selectionIndexPaths = [ip]
        collectionView.scrollToItems(at: [ip], scrollPosition: .nearestHorizontalEdge)
        refreshSelectionVisuals()
    }

    /// Синхронизирует рамку/тень выделения у видимых карточек по `selectedIndex`.
    /// Без reloadData(): не трогает превью и позицию скролла.
    private func refreshSelectionVisuals() {
        for ip in collectionView.indexPathsForVisibleItems() {
            (collectionView.item(at: ip) as? CardItem)?.setSelected(ip.item == selectedIndex)
        }
    }

    // MARK: Toast

    private func showToast(_ text: String) {
        toastView?.removeFromSuperview()
        let t = ToastView(text: text)
        t.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(t)
        NSLayoutConstraint.activate([
            t.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            t.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])
        toastView = t
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Theme.duration(0.15)
            t.animator().alphaValue = 1
        })
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak t, weak self] in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = Theme.duration(0.3)
                t?.animator().alphaValue = 0
            }, completionHandler: {
                t?.removeFromSuperview()
                if self?.toastView == t { self?.toastView = nil }
            })
        }
    }

    // MARK: Helpers

    private func captureBtn(_ sym: String, _ tip: String, action: @escaping () -> Void) -> HoverButton {
        let b = HoverButton(title: "", target: nil, action: nil)
        b.isBordered = false
        b.image = NSImage(systemSymbolName: sym, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        b.imagePosition = .imageOnly
        b.setFrameSize(NSSize(width: 30, height: 30))
        b.wantsLayer = true
        b.layer?.cornerRadius = 7
        b.restingTint = NSColor(white: 0.7, alpha: 1)
        b.hoverTint = .white
        b.hoverBackground = NSColor(white: 1, alpha: 0.12).cgColor
        b.toolTip = tip
        b.onAction = action
        return b
    }

    private func screenFor(button: NSStatusBarButton?) -> NSScreen {
        if let b = button, let win = b.window {
            let rect = win.convertToScreen(b.frame)
            return NSScreen.screens.first { $0.frame.contains(rect.origin) } ?? NSScreen.main ?? NSScreen.screens[0]
        }
        return NSScreen.main ?? NSScreen.screens[0]
    }
}

// MARK: - NSCollectionViewDataSource / Delegate

extension HistoryPanel: NSCollectionViewDataSource, NSCollectionViewDelegate, NSCollectionViewDelegateFlowLayout {

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        filtered().count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: .init("card"), for: indexPath) as! CardItem
        let entry = filtered()[indexPath.item]
        let isSelected = selectedIndex == indexPath.item
        item.configure(entry: entry, selected: isSelected, panel: self)
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let ip = indexPaths.first, selectedIndex != ip.item else { return }
        selectedIndex = ip.item
        // Точечно обновляем визуал, без reloadData() — иначе сбрасывается скролл и моргают превью.
        refreshSelectionVisuals()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        // selectedIndex авторитетно ставит didSelect (при переходе к другой карточке);
        // здесь только синхронизируем визуал видимых ячеек.
        refreshSelectionVisuals()
    }

    // Double-click = open
    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: any NSDraggingInfo, indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool { false }
}

// MARK: - CardItem (NSCollectionViewItem)

final class CardItem: NSCollectionViewItem {

    private let card = NSView()
    private let thumb = NSImageView()
    private let stamp = NSTextField(labelWithString: "")
    private let durationBadge = BadgeView()
    private let restoreButton = HoverButton(title: "", target: nil, action: nil)
    private let hoverOverlay = NSView()
    private var trackingArea: NSTrackingArea?
    private weak var panel: HistoryPanel?
    private var entry: HistoryEntry?
    private var thumbTask: Task<Void, Never>?

    // Hover action buttons
    private let editBtn = HoverButton(title: "", target: nil, action: nil)
    private let copyBtn = HoverButton(title: "", target: nil, action: nil)
    private let finderBtn = HoverButton(title: "", target: nil, action: nil)
    private let deleteBtn = HoverButton(title: "", target: nil, action: nil)

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: HistoryPanel.cardW, height: HistoryPanel.cardH))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildCard()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbTask?.cancel()
        thumbTask = nil
        entry = nil
        panel = nil
        thumb.image = nil
        hoverOverlay.alphaValue = 0
        restoreButton.alphaValue = 0
        stamp.alphaValue = 1
    }

    deinit {
        thumbTask?.cancel()
    }

    private func buildCard() {
        let W: CGFloat = HistoryPanel.cardW
        let H: CGFloat = HistoryPanel.cardH
        let tH: CGFloat = HistoryPanel.thumbH

        // Card background
        card.frame = NSRect(x: 0, y: 0, width: W, height: H)
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.cornerCurve = .continuous
        card.layer?.masksToBounds = false
        view.addSubview(card)

        // Thumb background (dark letterbox)
        let thumbBg = NSView(frame: NSRect(x: 0, y: H - tH, width: W, height: tH))
        thumbBg.wantsLayer = true
        thumbBg.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        thumbBg.layer?.cornerRadius = 10
        thumbBg.layer?.cornerCurve = .continuous
        thumbBg.layer?.masksToBounds = true
        card.addSubview(thumbBg)

        // Thumb image
        thumb.frame = thumbBg.bounds
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.translatesAutoresizingMaskIntoConstraints = false
        thumbBg.addSubview(thumb)
        NSLayoutConstraint.activate([
            thumb.topAnchor.constraint(equalTo: thumbBg.topAnchor),
            thumb.bottomAnchor.constraint(equalTo: thumbBg.bottomAnchor),
            thumb.leadingAnchor.constraint(equalTo: thumbBg.leadingAnchor),
            thumb.trailingAnchor.constraint(equalTo: thumbBg.trailingAnchor),
        ])

        // Duration badge (video/gif)
        durationBadge.translatesAutoresizingMaskIntoConstraints = false
        thumbBg.addSubview(durationBadge)
        NSLayoutConstraint.activate([
            durationBadge.trailingAnchor.constraint(equalTo: thumbBg.trailingAnchor, constant: -6),
            durationBadge.bottomAnchor.constraint(equalTo: thumbBg.bottomAnchor, constant: -6),
        ])

        // Hover overlay (scrim + action buttons)
        hoverOverlay.frame = NSRect(x: 0, y: H - tH, width: W, height: tH)
        hoverOverlay.wantsLayer = true
        hoverOverlay.layer?.backgroundColor = NSColor(white: 0, alpha: 0.42).cgColor
        hoverOverlay.layer?.cornerRadius = 10
        hoverOverlay.layer?.cornerCurve = .continuous
        hoverOverlay.layer?.masksToBounds = true
        hoverOverlay.alphaValue = 0
        card.addSubview(hoverOverlay)

        // Action buttons inside hover overlay
        for (btn, sym, tip) in [(editBtn, "scissors", NSLocalizedString("Редактировать", comment: "")),
                                 (copyBtn, "doc.on.doc", NSLocalizedString("Копировать", comment: "")),
                                 (finderBtn, "folder", NSLocalizedString("Показать в Finder", comment: "")),
                                 (deleteBtn, "trash", NSLocalizedString("Удалить", comment: ""))] {
            btn.isBordered = false
            btn.image = NSImage(systemSymbolName: sym, accessibilityDescription: tip)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
            btn.imagePosition = .imageOnly
            btn.setFrameSize(NSSize(width: 28, height: 28))
            btn.wantsLayer = true
            btn.layer?.cornerRadius = 7
            btn.layer?.masksToBounds = true
            btn.restingTint = .white
            btn.hoverTint = .white
            btn.restingBackground = NSColor(white: 0, alpha: 0.5).cgColor
            btn.hoverBackground = (sym == "trash" ? NSColor.systemRed : Theme.accent).cgColor
            btn.toolTip = tip
            btn.translatesAutoresizingMaskIntoConstraints = false
            hoverOverlay.addSubview(btn)
        }
        let actionStack = NSStackView(views: [editBtn, copyBtn, finderBtn, deleteBtn])
        actionStack.orientation = .horizontal
        actionStack.spacing = 6
        actionStack.translatesAutoresizingMaskIntoConstraints = false
        hoverOverlay.addSubview(actionStack)
        NSLayoutConstraint.activate([
            actionStack.centerXAnchor.constraint(equalTo: hoverOverlay.centerXAnchor),
            actionStack.centerYAnchor.constraint(equalTo: hoverOverlay.centerYAnchor),
        ])

        // Timestamp label
        stamp.frame = NSRect(x: 6, y: 4, width: W - 12, height: 18)
        stamp.font = .systemFont(ofSize: 11, weight: .medium)
        stamp.textColor = NSColor(white: 0.92, alpha: 1)
        stamp.alignment = .center
        card.addSubview(stamp)

        // Restore button (shown when selected)
        restoreButton.isBordered = false
        let attrTitle = NSAttributedString(string: NSLocalizedString("Восстановить", comment: ""), attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        restoreButton.attributedTitle = attrTitle
        restoreButton.setFrameSize(NSSize(width: W - 12, height: 22))
        restoreButton.frame = NSRect(x: 6, y: 3, width: W - 12, height: 22)
        restoreButton.wantsLayer = true
        restoreButton.layer?.cornerRadius = 6
        restoreButton.layer?.masksToBounds = true
        restoreButton.restingBackground = Theme.accent.cgColor
        restoreButton.hoverBackground = Theme.accent.withAlphaComponent(0.8).cgColor
        restoreButton.restingTint = .white
        restoreButton.hoverTint = .white
        restoreButton.alphaValue = 0
        card.addSubview(restoreButton)

        // Add click gesture
        let click = NSClickGestureRecognizer(target: self, action: #selector(cardClicked))
        click.numberOfClicksRequired = 1
        click.delegate = self
        card.addGestureRecognizer(click)

        let dblClick = NSClickGestureRecognizer(target: self, action: #selector(cardDoubleClicked))
        dblClick.numberOfClicksRequired = 2
        dblClick.delegate = self
        card.addGestureRecognizer(dblClick)

        // Drag support
        card.registerForDraggedTypes([.fileURL])
    }

    func configure(entry: HistoryEntry, selected: Bool, panel: HistoryPanel) {
        self.entry = entry
        self.panel = panel

        setSelected(selected, animated: false)

        // Иконка редактирования зависит от типа: видео → ножницы (обрезка), скриншот → square.and.pencil (аннотации).
        let editSym = entry.kind == .video ? "scissors" : "square.and.pencil"
        editBtn.image = NSImage(systemSymbolName: editSym, accessibilityDescription: NSLocalizedString("Редактировать", comment: ""))?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))

        stamp.stringValue = entry.relativeTimestamp

        // Duration badge
        switch entry.kind {
        case .video:
            durationBadge.isHidden = false
            if let dur = entry.duration, dur > 0 {
                durationBadge.configure(text: formatDuration(dur), icon: "video")
            } else {
                // длительность ещё грузится — показываем хотя бы иконку
                durationBadge.configure(text: NSLocalizedString("видео", comment: ""), icon: "video")
            }
        case .screenshot:
            durationBadge.isHidden = true
        }

        // Wire up restore button
        restoreButton.onAction = { [weak self] in
            guard let e = self?.entry else { return }
            self?.panel?.restoreEntry(e)
        }
        // Редактировать: openEntry сам выбирает редактор изображения (скриншот) или видеоредактор (видео).
        editBtn.onAction = { [weak self] in
            guard let e = self?.entry else { return }
            self?.panel?.openEntry(e)
        }
        copyBtn.onAction = { [weak self] in
            guard let e = self?.entry else { return }
            self?.panel?.copyEntry(e)
        }
        finderBtn.onAction = { [weak self] in
            guard let e = self?.entry else { return }
            self?.panel?.showInFinder(e)
        }
        deleteBtn.onAction = { [weak self] in
            guard let e = self?.entry else { return }
            self?.panel?.deleteEntry(e)
        }

        // Async thumbnail
        thumb.image = nil
        thumbTask?.cancel()
        thumbTask = Task { [weak self] in
            await self?.loadThumb(entry: entry)
        }
    }

    /// Обновляет только визуал выделения (рамка/тень/кнопка восстановления) —
    /// без перезагрузки превью. Вызывается при клике без полного reloadData().
    func setSelected(_ selected: Bool, animated: Bool = true) {
        card.layer?.borderWidth = selected ? 2.5 : 0
        card.layer?.borderColor = selected ? Theme.accent.cgColor : nil
        card.layer?.shadowOpacity = selected ? 0.5 : 0
        card.layer?.shadowRadius = selected ? 10 : 0
        card.layer?.shadowColor = selected ? Theme.accent.cgColor : nil

        let restoreAlpha: CGFloat = selected ? 1 : 0
        let stampAlpha: CGFloat = selected ? 0 : 1
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Theme.duration(0.12)
                restoreButton.animator().alphaValue = restoreAlpha
                stamp.animator().alphaValue = stampAlpha
            }
        } else {
            restoreButton.alphaValue = restoreAlpha
            stamp.alphaValue = stampAlpha
        }
    }

    private func loadThumb(entry: HistoryEntry) async {
        let mtime = entry.modDate
        if let cached = await ThumbnailCache.shared.get(entry.url, mtime: mtime) {
            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                // Ячейку могли переиспользовать под другой элемент — не подменяем чужое превью.
                guard self?.entry?.url == entry.url else { return }
                self?.thumb.image = cached
            }
            return
        }
        let image: NSImage?
        switch entry.kind {
        case .screenshot:
            image = await Task.detached(priority: .utility) {
                Self.makeThumbnail(url: entry.url)
            }.value
        case .video:
            image = await Task.detached(priority: .utility) {
                Self.makeVideoThumbnail(url: entry.url)
            }.value
        }
        guard let img = image, !Task.isCancelled else { return }
        await ThumbnailCache.shared.set(entry.url, mtime: mtime, image: img)
        await MainActor.run { [weak self] in
            guard self?.entry?.url == entry.url else { return }
            self?.thumb.image = img
        }
    }

    nonisolated private static func makeThumbnail(url: URL) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 400,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    nonisolated private static func makeVideoThumbnail(url: URL) -> NSImage? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 400, height: 300)
        let time = CMTime(seconds: 0.5, preferredTimescale: 600)

        // Use the non-deprecated sync API — runs on a background thread (detached task), so it's fine
        if let cg = try? gen.copyCGImage(at: time, actualTime: nil) {
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
        // Fallback: try at 0
        if let cg = try? gen.copyCGImage(at: .zero, actualTime: nil) {
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
        return nil
    }

    private func formatDuration(_ secs: Double) -> String {
        if secs < 60 {
            return String(format: NSLocalizedString("%d с", comment: "короткая длительность в секундах"), Int(secs.rounded()))
        }
        let m = Int(secs) / 60, s = Int(secs) % 60
        return String(format: "%d:%02d", m, s)
    }

    // MARK: Hover

    override func viewDidLayout() {
        super.viewDidLayout()
        updateTracking()
    }

    private func updateTracking() {
        if let t = trackingArea { view.removeTrackingArea(t) }
        let t = NSTrackingArea(rect: view.bounds,
                               options: [.activeAlways, .mouseEnteredAndExited, .cursorUpdate, .inVisibleRect],
                               owner: self, userInfo: nil)
        view.addTrackingArea(t)
        trackingArea = t
    }

    /// Курсор-«рука» над карточкой — она кликабельна (клик/двойной клик открывает).
    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }

    override func mouseEntered(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Theme.duration(0.15)
            hoverOverlay.animator().alphaValue = 1
        }
    }

    override func mouseExited(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Theme.duration(0.15)
            hoverOverlay.animator().alphaValue = 0
        }
    }

    // MARK: Click / drag

    @objc private func cardClicked(_ gr: NSClickGestureRecognizer) {
        guard entry != nil else { return }
        if let ip = collectionView?.indexPath(for: self) {
            // Лёгкий выбор без reloadData() — иначе сбрасывается скролл и моргают превью.
            panel?.selectIndex(ip.item)
        }
    }

    @objc private func cardDoubleClicked(_ gr: NSClickGestureRecognizer) {
        guard let entry else { return }
        panel?.openEntry(entry)
    }

    // Drag out
    override func mouseDragged(with event: NSEvent) {
        guard let entry else { return }
        let item = NSDraggingItem(pasteboardWriter: entry.url as NSURL)
        item.setDraggingFrame(thumb.frame, contents: thumb.image)
        view.beginDraggingSession(with: [item], event: event, source: self)
    }
}

extension CardItem: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}

extension CardItem: NSGestureRecognizerDelegate {
    // Не перехватывать клики, попадающие в кнопки (Восстановить / копировать / Finder / удалить),
    // иначе жест карточки съедает их нажатие.
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        if let hit = view.window?.contentView?.hitTest(event.locationInWindow), hit is NSButton {
            return false
        }
        return true
    }
}

// MARK: - TabBar

enum FilterTab: Int, CaseIterable {
    case all, screenshots, videos
    var label: String {
        switch self {
        case .all: return NSLocalizedString("Все", comment: "")
        case .screenshots: return NSLocalizedString("Снимки", comment: "")
        case .videos: return NSLocalizedString("Видео", comment: "")
        }
    }
}

final class TabBar: NSView {
    var onSelect: ((FilterTab) -> Void)?
    private var buttons: [NSButton] = []
    private let indicator = NSView()
    private var current: FilterTab = .all

    // Вся область — кликабельные вкладки → курсор-«рука».
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override init(frame: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 225, height: 32))
        buildTabs()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func buildTabs() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.08).cgColor
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous

        indicator.wantsLayer = true
        indicator.layer?.backgroundColor = Theme.accent.cgColor
        indicator.layer?.cornerRadius = 8
        indicator.layer?.cornerCurve = .continuous
        addSubview(indicator)

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        for tab in FilterTab.allCases {
            let btn = NSButton(title: tab.label, target: self, action: #selector(tabTapped(_:)))
            btn.isBordered = false
            btn.font = .systemFont(ofSize: 12, weight: .medium)
            btn.contentTintColor = NSColor(white: 0.65, alpha: 1)
            btn.tag = tab.rawValue
            btn.setFrameSize(NSSize(width: 72, height: 32))
            stack.addArrangedSubview(btn)
            buttons.append(btn)
        }

        widthAnchor.constraint(equalToConstant: 225).isActive = true
        heightAnchor.constraint(equalToConstant: 32).isActive = true
        layoutSubtreeIfNeeded()
        moveIndicator(to: .all, animated: false)
        updateButtonColors()
    }

    @objc private func tabTapped(_ sender: NSButton) {
        guard let tab = FilterTab(rawValue: sender.tag) else { return }
        current = tab
        moveIndicator(to: tab, animated: true)
        updateButtonColors()
        onSelect?(tab)
    }

    private func moveIndicator(to tab: FilterTab, animated: Bool) {
        let count = CGFloat(FilterTab.allCases.count)
        let w = (bounds.width - 4) / count
        let x = 2 + CGFloat(tab.rawValue) * w
        let rect = NSRect(x: x, y: 2, width: w, height: bounds.height - 4)
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Theme.duration(0.18)
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                indicator.animator().frame = rect
            }
        } else {
            indicator.frame = rect
        }
    }

    private func updateButtonColors() {
        for (i, btn) in buttons.enumerated() {
            btn.contentTintColor = i == current.rawValue
                ? .white
                : NSColor(white: 0.82, alpha: 1)
        }
    }
}

// MARK: - BadgeView

final class BadgeView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 60, height: 20))
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0, alpha: 0.65).cgColor
        layer?.cornerRadius = 6
        layer?.masksToBounds = true

        icon.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .white
        addSubview(icon)
        addSubview(label)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 11),
            icon.heightAnchor.constraint(equalToConstant: 11),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 3),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            // Без явной высоты вью схлопывается в 0 (translatesAutoresizing... = false)
            // и бейдж становится невидимым.
            heightAnchor.constraint(equalToConstant: 20),
        ])
        // Ширину держим прижатой к содержимому (иконка + текст).
        setContentHuggingPriority(.required, for: .horizontal)
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(text: String, icon sym: String?) {
        label.stringValue = text
        if let sym {
            icon.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
            icon.contentTintColor = .white
            icon.isHidden = false
        } else {
            icon.isHidden = true
        }
    }
}

// MARK: - ToastView

final class ToastView: NSView {
    init(text: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.15, alpha: 0.92).cgColor
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        alphaValue = 0

        let lbl = NSTextField(labelWithString: text)
        lbl.font = .systemFont(ofSize: 12, weight: .medium)
        lbl.textColor = .white
        lbl.translatesAutoresizingMaskIntoConstraints = false
        addSubview(lbl)
        NSLayoutConstraint.activate([
            lbl.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            lbl.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            lbl.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            lbl.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Notification

extension Notification.Name {
    static let screenshotkaOpenSettings = Notification.Name("screenshotkaOpenSettings")
}
