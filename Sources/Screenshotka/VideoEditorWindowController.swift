import AppKit
import AVFoundation
import AVKit

/// Мини-редактор записанного видео: триммер, размеры, аудио, качество, экспорт.
final class VideoEditorWindowController: NSWindowController, NSWindowDelegate {

    private let sourceURL: URL
    private let asset: AVURLAsset
    private let player: AVPlayer
    private let playerView = AVPlayerView()
    private let timeline = TrimTimelineView()

    private var duration: CMTime = .zero
    private var naturalSize: CGSize = .init(width: 1280, height: 720)
    private var videoFPS: Double = Double(Settings.shared.videoFPS)

    private var assetLoaded = false
    private var isExporting = false
    private var finished = false
    private var exportedURL: URL?
    private var exportSession: AVAssetExportSession?
    private var exportTask: Task<Void, Never>?   // отмена нового async-export (macOS 15+) — через cancel Task
    private var convertButton: HoverButton?
    private var cancelButton: HoverButton?
    private var presentationObs: NSKeyValueObservation?
    private var timeObserver: Any?
    private let exportSpinner = NSProgressIndicator()

    // Контролы.
    private let dimPopup = NSPopUpButton()
    private let fpsPopup = NSPopUpButton()
    private let widthField = NSTextField()
    private let heightField = NSTextField()
    private let qualitySlider = NSSlider(value: 0.7, minValue: 0.15, maxValue: 1.0, target: nil, action: nil)
    private let qualityLabel = NSTextField(labelWithString: NSLocalizedString("Среднее", comment: ""))
    private let sizeLabel = NSTextField(labelWithString: "≈ —")
    private var audioMode: AudioMode = .keep
    private var qualityTouched = false   // двигал ли пользователь слайдер качества
    private var sizeTouched = false      // менял ли пользователь размер вручную

    enum AudioMode { case keep, mute }

    /// Меняли ли размер кадра относительно оригинала.
    private var isResized: Bool {
        let nW = Int(naturalSize.width), nH = Int(naturalSize.height)
        let evenNat = CGSize(width: max(2, nW - nW % 2), height: max(2, nH - nH % 2))
        return targetSize != evenNat
    }
    /// Обрезан ли диапазон (триммер сдвинут от краёв).
    private var isTrimmed: Bool {
        let dur = CMTimeGetSeconds(duration)
        let start = CMTimeGetSeconds(timeline.startTime)
        let end = CMTimeGetSeconds(timeline.endTime)
        return start > 0.05 || (dur > 0 && end < dur - 0.05)
    }

    /// Нужно ли реально перекодировать видео. Перекодирование требуется только при
    /// смене размера / fps / качества. Обрезка и удаление звука делаются БЕЗ
    /// перекодирования (passthrough) — это в разы быстрее и без потери качества.
    private var needsReencode: Bool {
        isResized || fpsPopup.selectedTag() > 0 || qualityTouched
    }

    /// Пользователь реально что-то изменил (триммер / размер / fps / звук / качество)?
    /// Если нет — пересохранять видео не нужно, просто копируем исходник в буфер.
    private var hasEdits: Bool {
        isTrimmed || needsReencode || (audioMode == .mute)
    }

    var onClose: ((URL?) -> Void)?

    init(url: URL) {
        self.sourceURL = url
        self.asset = AVURLAsset(url: url)
        self.player = AVPlayer(url: url)

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 640),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = NSLocalizedString("Редактор видео", comment: "")
        w.appearance = NSAppearance(named: .darkAqua)
        // Минимальный размер: ниже него плеер + триммер + панель не помещаются,
        // и required-констрейнты вступили бы в конфликт.
        w.minSize = NSSize(width: 700, height: 620)
        w.center()
        super.init(window: w)
        w.delegate = self
        buildLayout()
        // Наблюдатель времени плеера → двигаем playhead на таймлайне (~30 кадр/с).
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600),
            queue: .main) { [weak self] time in
            guard let self else { return }
            self.timeline.setPlayhead(time)
            self.loopWithinSelectionIfNeeded(time)
        }
        Task { await loadAsset() }
    }

    func windowWillClose(_ notification: Notification) {
        guard !finished else { return }
        finished = true
        presentationObs?.invalidate()
        presentationObs = nil
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        exportTask?.cancel()           // новый async-export отменяется отменой задачи
        exportTask = nil
        exportSession?.cancelExport()  // legacy-путь (macOS < 15)
        exportSession = nil
        onClose?(exportedURL ?? sourceURL)
    }
    required init?(coder: NSCoder) { fatalError() }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        // Открываемся на паузе на первом кадре (как в классических видеоредакторах) —
        // воспроизведение по Пробелу/кнопке. Автоплей мешал выбирать диапазон.
        player.pause()
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        // AVPlayerView не пересчитывает внутренний слой видео при первом показе
        // (становится нормальным только после движения/перерисовки окна) — будим его.
        nudgePlayerLayout()
    }

    /// Зацикливаем воспроизведение в пределах выбранного диапазона (как превью клипа в NLE):
    /// дойдя до конца выделения, прыгаем к началу. Скраб/перетаскивание ручек паузят плеер,
    /// поэтому здесь работаем только при активном воспроизведении.
    private func loopWithinSelectionIfNeeded(_ time: CMTime) {
        guard player.rate > 0 else { return }
        let t = CMTimeGetSeconds(time)
        let start = CMTimeGetSeconds(timeline.startTime)
        let end = CMTimeGetSeconds(timeline.endTime)
        guard end - start > 0.1 else { return }
        if t >= end - 0.03 || t < start - 0.2 {
            player.seek(to: timeline.startTime, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    /// Принудительный перелейаут: AVPlayerView пересчитывает размер видеослоя только
    /// при РЕАЛЬНОЙ смене bounds. Кратковременно ужимаем кадр плеера и тут же
    /// возвращаем его автолейаутом — это даёт настоящий bounds-change (в отличие от
    /// микро-ресайза окна туда-обратно, который AppKit склеивает в нулевую дельту).
    private func nudgePlayerLayout() {
        guard let w = window else { return }
        w.contentView?.needsLayout = true
        w.contentView?.layoutSubtreeIfNeeded()

        let target = playerView.frame
        guard target.width > 2, target.height > 2 else { return }
        playerView.setFrameSize(NSSize(width: target.width - 1, height: target.height - 1))
        playerView.needsLayout = true
        w.contentView?.needsLayout = true
        w.contentView?.layoutSubtreeIfNeeded()   // вернёт плеер к target → реальный bounds-change
        playerView.needsDisplay = true
    }

    // MARK: - Layout

    private func buildLayout() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor

        playerView.player = player
        playerView.controlsStyle = .inline
        playerView.videoGravity = .resizeAspect
        playerView.translatesAutoresizingMaskIntoConstraints = false

        // AVPlayerView рисует видео крошечным, пока у item не появится presentationSize
        // (первый декодированный кадр). Ловим этот момент и пересчитываем раскладку —
        // иначе превью остаётся маленьким до первого ручного ресайза окна.
        presentationObs = player.observe(\.currentItem?.presentationSize, options: [.new]) { [weak self] _, _ in
            guard let self,
                  let s = self.player.currentItem?.presentationSize,
                  s.width > 0, s.height > 0 else { return }
            DispatchQueue.main.async { self.nudgePlayerLayout() }
        }

        timeline.translatesAutoresizingMaskIntoConstraints = false
        timeline.onChange = { [weak self] in self?.trimChanged() }
        // Скраб по таймлайну: тащим/кликаем по телу — перематываем плеер на эту позицию.
        timeline.onScrub = { [weak self] t in
            self?.player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        // Любое взаимодействие с таймлайном (скраб или перетаскивание ручек) — ставим
        // плеер на паузу: при выборе диапазона видео не должно играть автоплеем.
        timeline.onBeginInteraction = { [weak self] in self?.player.pause() }

        // Нижняя панель: размеры + аудио + качество.
        let panel = buildBottomPanel()
        panel.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(playerView)
        content.addSubview(timeline)
        content.addSubview(panel)

        // Якорим снизу: панель — по своему содержимому, триммер над ней,
        // плеер заполняет всё оставшееся сверху.
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            panel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            panel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),

            timeline.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            timeline.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            timeline.heightAnchor.constraint(equalToConstant: 72),
            timeline.bottomAnchor.constraint(equalTo: panel.topAnchor, constant: -16),

            playerView.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            playerView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            playerView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            playerView.bottomAnchor.constraint(equalTo: timeline.topAnchor, constant: -12),
        ])
        // Нижняя граница высоты плеера — мягкая (.defaultHigh), чтобы на крайних
        // размерах окна уступать, а не конфликтовать с required-констрейнтами.
        let playerFloor = playerView.heightAnchor.constraint(greaterThanOrEqualToConstant: 240)
        playerFloor.priority = .defaultHigh
        playerFloor.isActive = true
        // Низкий вертикальный hugging → именно плеер забирает свободную высоту окна.
        playerView.setContentHuggingPriority(.init(1), for: .vertical)
        playerView.setContentCompressionResistancePriority(.init(1), for: .vertical)
    }

    private func buildBottomPanel() -> NSView {
        let root = NSView()

        // — Размеры —
        let dimTitle = label(NSLocalizedString("Размеры:", comment: ""))
        dimPopup.target = self; dimPopup.action = #selector(dimPreset(_:))
        dimPopup.translatesAutoresizingMaskIntoConstraints = false
        [widthField, heightField].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.alignment = .left; $0.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            $0.target = self; $0.action = #selector(dimFieldChanged)
            $0.widthAnchor.constraint(equalToConstant: 72).isActive = true
        }
        let wTitle = label(NSLocalizedString("Ширина:", comment: "")), hTitle = label(NSLocalizedString("Высота:", comment: ""))

        let qTitle = label(NSLocalizedString("Качество:", comment: ""))
        qualitySlider.target = self; qualitySlider.action = #selector(qualityChanged)
        qualitySlider.translatesAutoresizingMaskIntoConstraints = false
        qualitySlider.numberOfTickMarks = 9          // деления как на референсе
        qualitySlider.allowsTickMarkValuesOnly = false
        qualityLabel.textColor = Theme.textSecondary; qualityLabel.font = .systemFont(ofSize: 12)

        // — Частота кадров —
        let fpsTitle = label(NSLocalizedString("Частота кадров:", comment: ""))
        fpsPopup.controlSize = .regular
        fpsPopup.translatesAutoresizingMaskIntoConstraints = false
        fpsPopup.addItem(withTitle: NSLocalizedString("Как в источнике", comment: "")); fpsPopup.lastItem?.tag = 0
        [60, 30, 24].forEach { fpsPopup.addItem(withTitle: "\($0) fps"); fpsPopup.lastItem?.tag = $0 }
        fpsPopup.selectItem(withTag: 0)
        fpsPopup.target = self; fpsPopup.action = #selector(fpsPickChanged(_:))

        let left = NSGridView(views: [
            [qTitle, sliderRow()],
            [fpsTitle, fpsPopup],
            [dimTitle, dimPopup],
            [wTitle, widthField],
            [hTitle, heightField],
        ])
        left.rowSpacing = 10; left.columnSpacing = 10
        left.column(at: 0).xPlacement = .trailing
        left.translatesAutoresizingMaskIntoConstraints = false

        // — Аудио — (радиогруппа: общий action + общий superview = взаимоисключение)
        let audTitle = label(NSLocalizedString("Звук:", comment: ""))
        let keep = NSButton(radioButtonWithTitle: NSLocalizedString("Не менять", comment: ""), target: self, action: #selector(audioPick(_:)))
        keep.tag = 0
        let mute = NSButton(radioButtonWithTitle: NSLocalizedString("Без звука", comment: ""), target: self, action: #selector(audioPick(_:)))
        mute.tag = 1
        keep.state = (audioMode == .keep) ? .on : .off
        mute.state = (audioMode == .mute) ? .on : .off
        let audStack = NSStackView(views: [keep, mute])
        audStack.orientation = .vertical; audStack.alignment = .leading; audStack.spacing = 8
        let right = NSGridView(views: [[audTitle, audStack]])
        right.column(at: 0).xPlacement = .trailing
        right.translatesAutoresizingMaskIntoConstraints = false

        // — Кнопки —
        sizeLabel.textColor = Theme.textSecondary; sizeLabel.font = .systemFont(ofSize: 12)
        let cancel = textButton(NSLocalizedString("Отмена", comment: ""), filled: false) { [weak self] in self?.cancel() }
        let convert = textButton(NSLocalizedString("Сохранить", comment: ""), filled: true) { [weak self] in self?.export() }
        convert.isEnabled = false   // включим после загрузки ассета
        cancelButton = cancel
        convertButton = convert
        exportSpinner.style = .spinning
        exportSpinner.controlSize = .small
        exportSpinner.isIndeterminate = true
        exportSpinner.isDisplayedWhenStopped = false
        exportSpinner.isHidden = true   // показываем только во время экспорта (NSStackView схлопывает скрытое)
        exportSpinner.translatesAutoresizingMaskIntoConstraints = false
        let bottomRow = NSStackView(views: [exportSpinner, sizeLabel, NSView(), cancel, convert])
        bottomRow.spacing = 12; bottomRow.alignment = .centerY
        bottomRow.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(left); root.addSubview(right); root.addSubview(bottomRow)
        // Высокоприоритетное равенство: кнопки сразу под гридами → панель прижата к
        // своему контенту и НЕ растягивается, выдавливая плеер вверх. >= оставляем как
        // страховку от наложения, если правый грид вдруг окажется выше левого.
        let hugBottom = bottomRow.topAnchor.constraint(equalTo: left.bottomAnchor, constant: 20)
        hugBottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            left.topAnchor.constraint(equalTo: root.topAnchor),
            left.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            right.topAnchor.constraint(equalTo: root.topAnchor),
            right.leadingAnchor.constraint(equalTo: left.trailingAnchor, constant: 40),
            hugBottom,
            bottomRow.topAnchor.constraint(greaterThanOrEqualTo: left.bottomAnchor, constant: 20),
            bottomRow.topAnchor.constraint(greaterThanOrEqualTo: right.bottomAnchor, constant: 20),
            bottomRow.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottomRow.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottomRow.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        return root
    }

    private func sliderRow() -> NSView {
        let s = NSStackView(views: [qualitySlider, qualityLabel])
        s.spacing = 8; s.alignment = .centerY
        qualitySlider.widthAnchor.constraint(equalToConstant: 160).isActive = true
        return s
    }

    private func label(_ t: String) -> NSTextField {
        let l = NSTextField(labelWithString: t)
        l.font = .systemFont(ofSize: 13); l.textColor = Theme.textSecondary
        return l
    }

    private func textButton(_ title: String, filled: Bool, action: @escaping () -> Void) -> HoverButton {
        let b = HoverButton(title: "", target: nil, action: nil)
        b.isBordered = false
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: filled ? NSColor.white : Theme.textPrimary,
            .font: NSFont.systemFont(ofSize: 13, weight: .medium)])
        b.wantsLayer = true
        b.layer?.cornerRadius = Theme.Radius.sm
        b.layer?.backgroundColor = filled ? Theme.accent.cgColor : NSColor(white: 1, alpha: 0.08).cgColor
        b.translatesAutoresizingMaskIntoConstraints = false
        b.heightAnchor.constraint(equalToConstant: 30).isActive = true
        b.widthAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true
        b.onAction = action
        return b
    }

    // MARK: - Load

    private func loadAsset() async {
        let dur = (try? await asset.load(.duration)) ?? .zero
        var size = CGSize(width: 1280, height: 720)
        var fps = Double(Settings.shared.videoFPS)
        if let track = try? await asset.loadTracks(withMediaType: .video).first {
            if let n = try? await track.load(.naturalSize) {
                size = CGSize(width: abs(n.width), height: abs(n.height))
            }
            if let rate = try? await track.load(.nominalFrameRate), rate > 0 {
                fps = Double(rate)
            }
        }
        await MainActor.run {
            self.duration = dur
            self.naturalSize = size
            self.videoFPS = fps
            self.setupDimPresets()
            self.fpsPopup.item(at: 0)?.title = String(format: NSLocalizedString("Как в источнике (%d fps)", comment: ""), Int(self.videoFPS.rounded()))
            self.timeline.configure(asset: self.asset, duration: dur)
            self.updateEstimate()
            self.assetLoaded = CMTimeGetSeconds(dur) > 0
            self.convertButton?.isEnabled = self.assetLoaded
            // Первый кадр мог прийти уже после показа окна — обновим раскладку плеера.
            self.nudgePlayerLayout()
        }
    }

    private func setupDimPresets() {
        dimPopup.removeAllItems()
        let w = Int(naturalSize.width), h = Int(naturalSize.height)
        dimPopup.addItem(withTitle: String(format: NSLocalizedString("%d × %d (оригинал)", comment: ""), w, h))
        let presets = [1080, 720, 480].filter { $0 < h }
        for p in presets {
            let pw = Int((Double(w) * Double(p) / Double(h)).rounded())
            dimPopup.addItem(withTitle: "\(pw) × \(p)")
        }
        widthField.stringValue = "\(w)"
        heightField.stringValue = "\(h)"
    }

    // MARK: - Actions

    @objc private func dimPreset(_ s: NSPopUpButton) {
        sizeTouched = true
        let title = s.titleOfSelectedItem ?? ""
        let nums = title.components(separatedBy: CharacterSet(charactersIn: "0123456789").inverted).compactMap { Int($0) }.filter { $0 > 0 }
        if nums.count >= 2 { widthField.stringValue = "\(nums[0])"; heightField.stringValue = "\(nums[1])"; updateEstimate() }
    }
    @objc private func dimFieldChanged() { sizeTouched = true; updateEstimate() }
    @objc private func qualityChanged() { qualityTouched = true; updateQualityLabel(); updateEstimate() }
    @objc private func audioPick(_ sender: NSButton) { audioMode = (sender.tag == 1) ? .mute : .keep; updateEstimate() }
    @objc private func fpsPickChanged(_ sender: NSPopUpButton) { updateEstimate() }

    /// Выбранный fps: тег 0 = «как в источнике» (исходный fps трека), иначе явное значение.
    private var selectedFPS: Double {
        let tag = fpsPopup.selectedTag()
        return tag > 0 ? Double(tag) : videoFPS
    }

    // Перемотку к перетаскиваемой ручке делает сам таймлайн через onScrub (превью in/out
    // кадра), плеер при этом на паузе — здесь только пересчёт оценки размера.
    private func trimChanged() { updateEstimate() }

    private func updateQualityLabel() {
        let q = qualitySlider.doubleValue
        qualityLabel.stringValue = q < 0.4 ? NSLocalizedString("Низкое", comment: "") : (q < 0.75 ? NSLocalizedString("Среднее", comment: "") : NSLocalizedString("Высокое", comment: ""))
    }

    private var targetSize: CGSize {
        let w = Int(widthField.stringValue) ?? Int(naturalSize.width)
        let h = Int(heightField.stringValue) ?? Int(naturalSize.height)
        return CGSize(width: max(2, w - w % 2), height: max(2, h - h % 2))
    }

    /// Размер для перекодирования. Если пользователь НЕ менял размер вручную —
    /// автоматически ограничиваем высоту 1080p: перекодирование Retina 2× в полном
    /// разрешении — самое долгое, а 1080p в разы быстрее и сильно легче по весу.
    /// Явно выбранное разрешение уважаем без ограничения.
    private func effectiveRenderSize() -> CGSize {
        let s = targetSize
        let cap: CGFloat = 1080
        guard !sizeTouched, s.height > cap else { return s }
        var w = Int((s.width * cap / s.height).rounded())
        w -= w % 2
        return CGSize(width: max(2, w), height: Int(cap))
    }
    private var trimDuration: Double {
        max(0.1, CMTimeGetSeconds(timeline.endTime) - CMTimeGetSeconds(timeline.startTime))
    }
    private var estimatedBytes: Int64 {
        let s = effectiveRenderSize()   // учитываем авто-1080p, чтобы оценка совпадала с реальностью
        let bpp = 0.04 + qualitySlider.doubleValue * 0.16   // битность на пиксель·кадр
        let fps = selectedFPS                               // выбранный пользователем fps
        let videoBps = bpp * Double(s.width) * Double(s.height) * fps
        let audioBps = (audioMode == .mute) ? 0 : 128_000.0
        return Int64((videoBps + audioBps) * trimDuration / 8.0)
    }
    private func updateEstimate() {
        let mb = Double(estimatedBytes) / 1_048_576.0
        sizeLabel.stringValue = String(format: NSLocalizedString("≈ %.1f МБ", comment: ""), mb)
        updateQualityLabel()
    }

    private func cancel() {
        // Закрытие идёт через windowWillClose (там пауза/освобождение/onClose).
        window?.close()
    }

    private func export() {
        guard assetLoaded, !isExporting, !finished else { return }
        isExporting = true
        player.pause()

        // Ничего не меняли → не создаём дубликат файла: просто копируем исходник в буфер и закрываем.
        if !hasEdits {
            exportedURL = sourceURL
            ImageStore.copyFileToClipboard(sourceURL)
            convertButton?.isEnabled = false
            sizeLabel.stringValue = NSLocalizedString("Скопировано ✓", comment: "")
            sizeLabel.textColor = Theme.accent
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, !self.finished else { return }
                self.window?.close()
            }
            return
        }

        beginProgressUI()   // мгновенная обратная связь (<100 мс): спиннер + «Подготовка…»

        let out = ImageStore.uniqueURL(in: Settings.shared.saveFolder, name: String(format: NSLocalizedString("Видео %@", comment: ""), Self.stamp()), ext: "mp4")
        let range = CMTimeRange(start: timeline.startTime, end: timeline.endTime)
        let size = effectiveRenderSize()   // авто-1080p при перекодировании (если размер не задан вручную)
        let mute = (audioMode == .mute)
        // Лимит размера — это и есть рычаг «качества» для пресета HEVCHighestQuality.
        // Применяем только если пользователь сам двигал слайдер, и с запасом 30%:
        // эвристика bpp занижает оценку для динамичного контента.
        let limit: Int64 = qualityTouched ? Int64(Double(estimatedBytes) * 1.3) : 0
        let fps = selectedFPS
        let reencode = needsReencode   // false → быстрый passthrough (обрезка/звук без перекодирования)

        exportTask = Task { [weak self] in
            guard let self else { return }
            let onSession: (AVAssetExportSession) -> Void = { [weak self] s in
                DispatchQueue.main.async { [weak self] in self?.exportSession = s }
            }
            let onProgress: (Double) -> Void = { [weak self] frac in self?.updateExportPercent(frac) }
            let ok: Bool
            if reencode {
                ok = await Self.exportVideo(asset: self.asset, to: out, range: range,
                                            renderSize: size, mute: mute, fileLengthLimit: limit,
                                            frameRate: fps,
                                            onSession: onSession, onProgress: onProgress)
            } else {
                // Только обрезка и/или удаление звука — копируем потоки без перекодирования.
                ok = await Self.exportPassthrough(asset: self.asset, to: out, range: range,
                                                  mute: mute, onSession: onSession, onProgress: onProgress)
            }
            await MainActor.run {
                self.exportSession = nil
                self.isExporting = false
                if self.finished { return }   // окно уже закрыли/отменили
                if ok {
                    self.exportedURL = out
                    ImageStore.copyFileToClipboard(out)
                    self.finishProgressUI(success: true)   // «Готово ✓» → короткая пауза → закрытие
                } else {
                    self.finishProgressUI(success: false)
                    let a = NSAlert()
                    a.messageText = NSLocalizedString("Не удалось экспортировать видео", comment: "")
                    a.informativeText = NSLocalizedString("Попробуйте другие параметры (диапазон, размер или качество).", comment: "")
                    a.runModal()
                }
            }
        }
    }

    // MARK: - Прогресс экспорта

    private func setConvertTitle(_ t: String) {
        convertButton?.attributedTitle = NSAttributedString(string: t, attributes: [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 13, weight: .medium)])
    }

    private func beginProgressUI() {
        convertButton?.isEnabled = false
        setConvertTitle(NSLocalizedString("Сохранение…", comment: ""))
        exportSpinner.isHidden = false
        exportSpinner.startAnimation(nil)
        sizeLabel.stringValue = NSLocalizedString("Подготовка…", comment: "")
        sizeLabel.textColor = Theme.accent
    }

    /// Реальный процент из потока состояний экспорта (вызывается на главном потоке).
    private func updateExportPercent(_ fraction: Double) {
        guard isExporting else { return }
        let p = max(0, min(100, Int((fraction * 100).rounded())))
        sizeLabel.stringValue = String(format: NSLocalizedString("Сохранение… %d %%", comment: ""), p)
    }

    private func finishProgressUI(success: Bool) {
        exportSpinner.stopAnimation(nil)
        exportSpinner.isHidden = true
        if success {
            sizeLabel.stringValue = NSLocalizedString("Готово ✓", comment: "")
            sizeLabel.textColor = Theme.accent
            // Короткая фиксация успеха, затем закрываем — окно не «зависает» и не дёргается.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { [weak self] in
                guard let self, !self.finished else { return }
                self.window?.close()
            }
        } else {
            sizeLabel.textColor = Theme.textSecondary
            updateEstimate()
            setConvertTitle(NSLocalizedString("Сохранить", comment: ""))
            convertButton?.isEnabled = true
        }
    }

    private static func stamp() -> String {
        let f = DateFormatter(); f.dateFormat = NSLocalizedString("yyyy-MM-dd 'в' HH.mm.ss", comment: ""); return f.string(from: Date())
    }

    // MARK: - Export engine

    /// Быстрый экспорт БЕЗ перекодирования (passthrough): только обрезка диапазона и/или
    /// удаление звука. Копирует исходные видео/аудио-потоки → в разы быстрее полного
    /// перекодирования и без потери качества. Все аудиодорожки сохраняются (если не mute).
    static func exportPassthrough(asset: AVURLAsset, to outURL: URL, range: CMTimeRange,
                                  mute: Bool,
                                  onSession: ((AVAssetExportSession) -> Void)? = nil,
                                  onProgress: ((Double) -> Void)? = nil) async -> Bool {
        guard let vTrack = try? await asset.loadTracks(withMediaType: .video).first else { return false }
        let assetDuration = (try? await asset.load(.duration)) ?? range.duration

        // Кламп диапазона к длительности (иначе insert/ export может зависнуть/упасть).
        let durSec = CMTimeGetSeconds(assetDuration)
        let startS = max(0, min(CMTimeGetSeconds(range.start), durSec))
        let endS = max(startS, min(CMTimeGetSeconds(range.end), durSec))
        guard endS - startS >= 0.05 else { return false }
        // Кламп в CMTime: квантование секунд в timescale 600 может дать end чуть БОЛЬШЕ
        // точной длительности дорожки — insertTimeRange такого не прощает.
        let startT = min(CMTime(seconds: startS, preferredTimescale: 600), assetDuration)
        let endT = min(CMTime(seconds: endS, preferredTimescale: 600), assetDuration)
        let r = CMTimeRange(start: startT, end: endT)

        // Композиция: видеодорожка + все аудиодорожки (если не mute) за диапазон.
        let comp = AVMutableComposition()
        guard let cv = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { return false }
        do { try cv.insertTimeRange(r, of: vTrack, at: .zero) } catch { return false }
        cv.preferredTransform = (try? await vTrack.load(.preferredTransform)) ?? .identity
        if !mute, let aTracks = try? await asset.loadTracks(withMediaType: .audio) {
            for aTrack in aTracks {
                if let ca = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                    try? ca.insertTimeRange(r, of: aTrack, at: .zero)
                }
            }
        }

        try? FileManager.default.removeItem(at: outURL)
        guard let session = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else { return false }
        onSession?(session)

        if #available(macOS 15.0, *) {
            let progressTask = Task {
                for await state in session.states(updateInterval: 0.1) {
                    if case .exporting(let p) = state {
                        let frac = p.fractionCompleted
                        await MainActor.run { onProgress?(frac) }
                    }
                }
            }
            defer { progressTask.cancel() }
            do { try await session.export(to: outURL, as: .mp4); return true } catch { return false }
        } else {
            session.outputURL = outURL
            session.outputFileType = .mp4
            await session.export()
            return session.status == .completed
        }
    }

    static func exportVideo(asset: AVURLAsset, to outURL: URL, range: CMTimeRange,
                            renderSize: CGSize, mute: Bool, fileLengthLimit: Int64,
                            frameRate: Double = 60,
                            onSession: ((AVAssetExportSession) -> Void)? = nil,
                            onProgress: ((Double) -> Void)? = nil) async -> Bool {
        // HEVC-пресет: H.265 даёт тот же визуальный результат при ~40–50% меньшем размере.
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHEVCHighestQuality) else { return false }
        try? FileManager.default.removeItem(at: outURL)
        let assetDuration = (try? await asset.load(.duration)) ?? range.duration
        let natural = (try? await track.load(.naturalSize)) ?? renderSize
        let pref = (try? await track.load(.preferredTransform)) ?? .identity

        // Кламп диапазона к длительности ассета (иначе export() зависает при end >= duration).
        let durSec = CMTimeGetSeconds(assetDuration)
        let startS = max(0, min(CMTimeGetSeconds(range.start), durSec))
        let endS = max(startS, min(CMTimeGetSeconds(range.end), durSec))
        guard endS - startS >= 0.05 else { return false }

        // Кламп размера к чётным значениям >= 16.
        var w = Int(renderSize.width.rounded()), h = Int(renderSize.height.rounded())
        w = max(16, w - w % 2); h = max(16, h - h % 2)
        let size = CGSize(width: w, height: h)

        // Размер источника с учётом поворота (preferredTransform).
        let displayRect = CGRect(origin: .zero, size: natural).applying(pref)
        let dispW = abs(displayRect.width), dispH = abs(displayRect.height)
        let sx = size.width / max(1, dispW), sy = size.height / max(1, dispH)
        let normalize = CGAffineTransform(translationX: -min(0, displayRect.minX), y: -min(0, displayRect.minY))
        let finalTransform = pref.concatenating(normalize).concatenating(CGAffineTransform(scaleX: sx, y: sy))

        session.videoComposition = makeVideoComposition(track: track, duration: assetDuration,
                                                        renderSize: size, transform: finalTransform,
                                                        frameRate: frameRate)
        session.timeRange = CMTimeRange(start: min(CMTime(seconds: startS, preferredTimescale: 600), assetDuration),
                                        end: min(CMTime(seconds: endS, preferredTimescale: 600), assetDuration))
        if fileLengthLimit > 200_000 { session.fileLengthLimit = fileLengthLimit }   // игнорируем слишком малый лимит
        if mute {
            let mix = AVMutableAudioMix()
            var params: [AVMutableAudioMixInputParameters] = []
            if let atracks = try? await asset.loadTracks(withMediaType: .audio) {
                for t in atracks { let p = AVMutableAudioMixInputParameters(track: t); p.setVolume(0, at: .zero); params.append(p) }
            }
            mix.inputParameters = params
            session.audioMix = mix
        }

        onSession?(session)

        // Новый async-API (macOS 15+): старый export()/status/progress помечен deprecated и на
        // macOS 26 завершается ошибкой. Прогресс берём из потока состояний states(updateInterval:).
        if #available(macOS 15.0, *) {
            let progressTask = Task {
                for await state in session.states(updateInterval: 0.1) {
                    if case .exporting(let p) = state {
                        let frac = p.fractionCompleted
                        await MainActor.run { onProgress?(frac) }
                    }
                }
            }
            defer { progressTask.cancel() }
            do {
                try await session.export(to: outURL, as: .mp4)
                return true
            } catch {
                return false   // включая отмену — её обрабатывает вызывающий по флагу finished
            }
        } else {
            session.outputURL = outURL
            session.outputFileType = .mp4
            await session.export()
            return session.status == .completed
        }
    }

    /// Видео-композиция для ресайза. Новый API на macOS 26+, legacy — для более старых.
    private static func makeVideoComposition(track: AVAssetTrack, duration: CMTime,
                                             renderSize: CGSize, transform: CGAffineTransform,
                                             frameRate: Double = 60) -> AVVideoComposition {
        let ts = Int32(max(1, frameRate.rounded()))
        if #available(macOS 26.0, *) {
            var layerCfg = AVVideoCompositionLayerInstruction.Configuration(assetTrack: track)
            layerCfg.setTransform(transform, at: .zero)
            let layer = AVVideoCompositionLayerInstruction(configuration: layerCfg)

            var instCfg = AVVideoCompositionInstruction.Configuration()
            instCfg.timeRange = CMTimeRange(start: .zero, duration: duration)
            instCfg.layerInstructions = [layer]
            let inst = AVVideoCompositionInstruction(configuration: instCfg)

            var cfg = AVVideoComposition.Configuration()
            cfg.renderSize = renderSize
            cfg.frameDuration = CMTime(value: 1, timescale: ts)
            cfg.instructions = [inst]
            return AVVideoComposition(configuration: cfg)
        } else {
            return legacyVideoComposition(track: track, duration: duration, renderSize: renderSize, transform: transform, frameRate: frameRate)
        }
    }

    /// Старый API (до macOS 26). Обёртка помечена deprecated — внутренние предупреждения подавляются.
    @available(macOS, deprecated: 26.0)
    private static func legacyVideoComposition(track: AVAssetTrack, duration: CMTime,
                                               renderSize: CGSize, transform: CGAffineTransform,
                                               frameRate: Double = 60) -> AVVideoComposition {
        let comp = AVMutableVideoComposition()
        comp.renderSize = renderSize
        comp.frameDuration = CMTime(value: 1, timescale: Int32(max(1, frameRate.rounded())))
        let inst = AVMutableVideoCompositionInstruction()
        inst.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(transform, at: .zero)
        inst.layerInstructions = [layer]
        comp.instructions = [inst]
        return comp
    }
}

// MARK: - Триммер с миниатюрами и жёлтыми ручками

final class TrimTimelineView: NSView {
    var onChange: (() -> Void)?
    var onScrub: ((CMTime) -> Void)?           // перемотка плеера при клике/драге по телу/ручке
    var onBeginInteraction: (() -> Void)?      // начало взаимодействия → плеер на паузу

    private var duration: CMTime = .zero
    private(set) var startFrac: CGFloat = 0
    private(set) var endFrac: CGFloat = 1
    private var playheadFrac: CGFloat = 0   // текущая позиция просмотра (0…1)
    private var thumbs: [NSImage] = []
    private var thumbMap: [Double: NSImage] = [:]   // keyed by requested seconds (main-thread only)
    private var imageGenerator: AVAssetImageGenerator?
    private enum Drag { case none, left, right, scrub }
    private var drag: Drag = .none

    /// Обновление позиции просмотра из наблюдателя времени плеера.
    func setPlayhead(_ time: CMTime) {
        let total = CMTimeGetSeconds(duration)
        guard total > 0 else { return }
        let f = CGFloat(min(max(CMTimeGetSeconds(time) / total, 0), 1))
        guard abs(f - playheadFrac) > 0.0005 else { return }
        playheadFrac = f
        needsDisplay = true
    }

    private func time(at frac: CGFloat) -> CMTime {
        CMTime(seconds: CMTimeGetSeconds(duration) * Double(min(max(frac, 0), 1)), preferredTimescale: 600)
    }

    deinit {
        imageGenerator?.cancelAllCGImageGeneration()
    }

    var startTime: CMTime { CMTime(seconds: CMTimeGetSeconds(duration) * Double(startFrac), preferredTimescale: 600) }
    var endTime: CMTime { CMTime(seconds: CMTimeGetSeconds(duration) * Double(endFrac), preferredTimescale: 600) }

    override var isFlipped: Bool { true }

    func configure(asset: AVURLAsset, duration: CMTime) {
        self.duration = duration
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor(white: 0.18, alpha: 1).cgColor
        generateThumbs(asset: asset, duration: duration)
        needsDisplay = true
    }

    private func generateThumbs(asset: AVURLAsset, duration: CMTime) {
        imageGenerator?.cancelAllCGImageGeneration()
        let gen = AVAssetImageGenerator(asset: asset)
        imageGenerator = gen
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 160, height: 90)
        let count = 10
        let total = CMTimeGetSeconds(duration)
        guard total > 0 else { return }
        let times = (0..<count).map { NSValue(time: CMTime(seconds: total * Double($0) / Double(count), preferredTimescale: 600)) }
        thumbMap.removeAll()
        gen.generateCGImagesAsynchronously(forTimes: times) { [weak self] requested, image, _, result, _ in
            guard result == .succeeded, let image else { return }
            let key = CMTimeGetSeconds(requested)
            let img = NSImage(cgImage: image, size: .zero)
            // Аккумулируем строго на главном потоке (колбэк может приходить из разных потоков).
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.imageGenerator === gen else { return }
                self.thumbMap[key] = img
                self.thumbs = self.thumbMap.keys.sorted().compactMap { self.thumbMap[$0] }
                self.needsDisplay = true
            }
        }
    }

    // MARK: Mouse

    private var handleW: CGFloat { 12 }
    private func x(_ frac: CGFloat) -> CGFloat { bounds.minX + frac * bounds.width }

    // Курсор «изменения размера» над ручками триммера.
    override func resetCursorRects() {
        let hw: CGFloat = 16
        addCursorRect(NSRect(x: x(startFrac) - hw, y: 0, width: hw * 2, height: bounds.height), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: x(endFrac) - hw, y: 0, width: hw * 2, height: bounds.height), cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        onBeginInteraction?()   // пауза: при выборе диапазона видео не играет
        let p = convert(event.locationInWindow, from: nil)
        if abs(p.x - x(startFrac)) < 16 {
            drag = .left; playheadFrac = startFrac; needsDisplay = true
            onScrub?(startTime)               // превью кадра начала (in)
        } else if abs(p.x - x(endFrac)) < 16 {
            drag = .right; playheadFrac = endFrac; needsDisplay = true
            onScrub?(endTime)                 // превью кадра конца (out)
        } else {
            // Клик по телу таймлайна — перемотка просмотра на эту точку.
            drag = .scrub
            scrub(to: p)
        }
    }
    override func mouseDragged(with event: NSEvent) {
        guard drag != .none else { return }
        let p = convert(event.locationInWindow, from: nil)
        if drag == .scrub { scrub(to: p); return }
        let frac = min(max((p.x - bounds.minX) / bounds.width, 0), 1)
        // Плейхед следует за перетаскиваемой ручкой → плеер показывает её кадр (in/out).
        if drag == .left { startFrac = min(frac, endFrac - 0.02); playheadFrac = startFrac }
        else { endFrac = max(frac, startFrac + 0.02); playheadFrac = endFrac }
        needsDisplay = true
        window?.invalidateCursorRects(for: self)   // ручки сдвинулись — обновляем зоны курсора
        onChange?()
        onScrub?(time(at: playheadFrac))           // перемотка плеера на кадр ручки (на паузе)
    }
    override func mouseUp(with event: NSEvent) { drag = .none }

    private func scrub(to p: NSPoint) {
        let frac = min(max((p.x - bounds.minX) / bounds.width, 0), 1)
        playheadFrac = frac
        needsDisplay = true
        onScrub?(time(at: frac))
    }

    override func draw(_ dirtyRect: NSRect) {
        // миниатюры
        if !thumbs.isEmpty {
            let tw = bounds.width / CGFloat(thumbs.count)
            for (i, img) in thumbs.enumerated() {
                img.draw(in: NSRect(x: bounds.minX + CGFloat(i) * tw, y: 0, width: tw, height: bounds.height))
            }
        }
        // затемнение вне выделения
        NSColor(white: 0, alpha: 0.55).setFill()
        NSBezierPath(rect: NSRect(x: bounds.minX, y: 0, width: x(startFrac) - bounds.minX, height: bounds.height)).fill()
        NSBezierPath(rect: NSRect(x: x(endFrac), y: 0, width: bounds.maxX - x(endFrac), height: bounds.height)).fill()
        // рамка выделения (жёлтая)
        let sel = NSRect(x: x(startFrac), y: 0, width: x(endFrac) - x(startFrac), height: bounds.height)
        NSColor.systemYellow.setStroke()
        let border = NSBezierPath(rect: sel.insetBy(dx: 1, dy: 1)); border.lineWidth = 3; border.stroke()
        // ручки
        NSColor.systemYellow.setFill()
        for fx in [x(startFrac), x(endFrac)] {
            NSBezierPath(roundedRect: NSRect(x: fx - handleW/2, y: 0, width: handleW, height: bounds.height), xRadius: 4, yRadius: 4).fill()
        }
        // playhead — текущая позиция просмотра: белая линия с «головкой» сверху и тенью.
        let px = x(playheadFrac)
        let line = NSBezierPath(rect: NSRect(x: px - 1, y: 0, width: 2, height: bounds.height))
        NSColor(white: 0, alpha: 0.35).setStroke()
        let halo = NSBezierPath(rect: NSRect(x: px - 1.5, y: 0, width: 3, height: bounds.height))
        halo.lineWidth = 0; NSColor(white: 0, alpha: 0.25).setFill(); halo.fill()
        NSColor.white.setFill(); line.fill()
        let knob = NSBezierPath(ovalIn: NSRect(x: px - 5, y: -1, width: 10, height: 10))
        NSColor.white.setFill(); knob.fill()
        NSColor(white: 0, alpha: 0.25).setStroke(); knob.lineWidth = 1; knob.stroke()
    }
}
