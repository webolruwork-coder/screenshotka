import AppKit
import ScreenCaptureKit
import AVFoundation

/// Запись области экрана в видеофайл (.mp4) через ScreenCaptureKit + AVAssetWriter.
/// Поддерживает паузу/возобновление (через сдвиг таймстампов), рестарт и отмену.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate {

    enum State { case idle, recording, paused, finishing }
    private(set) var state: State = .idle

    var onError: ((String) -> Void)?
    var onStopped: ((URL?) -> Void)?

    // Параметры текущей сессии (для рестарта).
    private var rect: CGRect = .zero
    private var screen: NSScreen?
    private var micEnabled = false
    private var systemAudioEnabled = true
    private var fps: Int = 60
    private var micDeviceID: String?
    private var exceptingWindowNumber: Int?

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var micInput: AVAssetWriterInput?
    private(set) var url: URL?

    private var sessionStarted = false
    private var timeOffset = CMTime.zero
    private var lastVideoPTS = CMTime.zero
    private var resuming = false          // читается/сбрасывается только на queue
    private var writeFailed = false       // однократное уведомление о провале записи файла

    private let queue = DispatchQueue(label: "screenshotka.recorder")
    private let stateLock = NSLock()

    /// Атомарный переход состояния. Возвращает false, если текущее состояние не из allowed.
    @discardableResult
    private func transition(to newState: State, from allowed: [State]) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        guard allowed.contains(state) else { return false }
        state = newState
        return true
    }
    private func setState(_ s: State) {
        stateLock.lock(); state = s; stateLock.unlock()
    }
    /// Потокобезопасное чтение состояния (обработчики кадров идут на queue, переходы — с main).
    private var currentState: State {
        stateLock.lock(); defer { stateLock.unlock() }
        return state
    }

    // MARK: - Public

    func start(rect: CGRect, screen: NSScreen, mic: Bool, systemAudio: Bool, fps: Int,
               micDeviceID: String? = nil, exceptingWindowNumber: Int? = nil) async throws {
        // Защита от двойного старта (например, повторный хоткей во время обратного отсчёта):
        // иначе второй start перезаписал бы writer/stream идущей записи.
        guard currentState == .idle else {
            throw NSError(domain: "rec", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Запись уже идёт", comment: "")])
        }
        self.rect = rect
        self.screen = screen
        self.micEnabled = mic
        self.systemAudioEnabled = systemAudio
        self.fps = fps
        self.micDeviceID = micDeviceID
        self.exceptingWindowNumber = exceptingWindowNumber
        resetTimingState()

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else {
            throw NSError(domain: "rec", code: 1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Дисплей не найден", comment: "")])
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownApps = content.applications.filter { $0.processID == ownPID }
        // Retina→1x по настройке.
        let scale = Settings.shared.scaleRetinaTo1x ? 1.0 : screen.backingScaleFactor

        // Камеру (окно-пузырь) НЕ исключаем — она должна попасть в кадр.
        var excepting: [SCWindow] = []
        if let wn = exceptingWindowNumber,
           let w = content.windows.first(where: { $0.windowID == CGWindowID(wn) }) {
            excepting = [w]
        }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: excepting)
        let config = SCStreamConfiguration()
        // Регион в точках, origin сверху-слева относительно дисплея.
        config.sourceRect = CGRect(x: rect.minX - screen.frame.minX,
                                   y: screen.frame.maxY - rect.maxY,
                                   width: rect.width, height: rect.height)
        var pxW = Int((rect.width * scale).rounded()), pxH = Int((rect.height * scale).rounded())
        // Ограничение по макс. высоте (с сохранением пропорций).
        let maxH = Settings.shared.maxVideoHeight
        if maxH > 0, pxH > maxH {
            pxW = Int((Double(pxW) * Double(maxH) / Double(pxH)).rounded())
            pxH = maxH
        }
        pxW -= pxW % 2; pxH -= pxH % 2   // чётные размеры для H.264
        pxW = max(2, pxW); pxH = max(2, pxH)
        config.width = pxW
        config.height = pxH
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = 6
        config.showsCursor = Settings.shared.showCursorInVideo
        config.scalesToFit = true
        config.pixelFormat = kCVPixelFormatType_32BGRA
        if systemAudio { config.capturesAudio = true }
        if mic, #available(macOS 15.0, *) {
            config.captureMicrophone = true
            if let id = micDeviceID { config.microphoneCaptureDeviceID = id }
        }

        try setupWriter(pxW: pxW, pxH: pxH, fps: fps, mic: mic, systemAudio: systemAudio)

        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if systemAudio { try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        if mic, #available(macOS 15.0, *) { try s.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue) }
        self.stream = s
        try await s.startCapture()
        setState(.recording)
    }

    func pause() {
        transition(to: .paused, from: [.recording])
    }

    func resume() {
        if transition(to: .recording, from: [.paused]) {
            // Флаг читается/сбрасывается на queue — выставляем его там же (без гонки).
            queue.async { [weak self] in self?.resuming = true }
        }
    }

    /// Останавливает запись и финализирует файл. Возвращает URL готового видео.
    @discardableResult
    func stop() async -> URL? {
        // Атомарно: только один stop/cancel может перейти в .finishing.
        guard transition(to: .finishing, from: [.recording, .paused]) else { return nil }
        try? await stream?.stopCapture()
        queue.sync {}   // дождаться обработки последних буферов

        var result: URL? = nil
        if sessionStarted, let writer = writer, writer.status == .writing {
            // Финализируем, только если запись реально началась (иначе markAsFinished падает).
            videoInput?.markAsFinished()
            audioInput?.markAsFinished()
            micInput?.markAsFinished()
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                writer.finishWriting { cont.resume() }
            }
            result = (writer.status == .completed) ? url : nil
        } else {
            // Ни одного кадра — файла нет/пустой, удаляем.
            if writer?.status == .writing { writer?.cancelWriting() }
            if let u = url { try? FileManager.default.removeItem(at: u) }
        }
        cleanup()
        setState(.idle)
        return result
    }

    /// Отмена: остановить и удалить файл.
    func cancel() async {
        guard transition(to: .finishing, from: [.recording, .paused]) else { return }
        try? await stream?.stopCapture()
        queue.sync {}
        if writer?.status == .writing { writer?.cancelWriting() }
        if let url = url { try? FileManager.default.removeItem(at: url) }
        cleanup()
        setState(.idle)
    }

    /// Рестарт: отменить текущую и начать заново с той же областью.
    func restart() async throws {
        guard let screen = screen else { return }
        let r = rect, mic = micEnabled, sys = systemAudioEnabled, f = fps
        let did = micDeviceID, win = exceptingWindowNumber
        await cancel()
        try await start(rect: r, screen: screen, mic: mic, systemAudio: sys, fps: f,
                        micDeviceID: did, exceptingWindowNumber: win)
    }

    // MARK: - Setup

    private func setupWriter(pxW: Int, pxH: Int, fps: Int, mic: Bool, systemAudio: Bool) throws {
        let name = String(format: NSLocalizedString("Запись %@.mp4", comment: ""), Self.timestamp())
        let outURL = Settings.shared.saveFolder.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: outURL)
        let w = try AVAssetWriter(outputURL: outURL, fileType: .mp4)

        // Осознанный битрейт для экранного контента (много статики → хорошо сжимается).
        // HEVC + B-кадры + редкие опорные кадры дают визуально-без-потерь картинку,
        // но в разы меньший файл, чем дефолтный (неконтролируемый) битрейт AVAssetWriter.
        let bitsPerPixel = 0.07
        let f = max(1, fps)
        let rawBitrate = Double(pxW * pxH) * Double(f) * bitsPerPixel
        let targetBitrate = Int(min(45_000_000, max(1_500_000, rawBitrate)))

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,   // H.265 — современнее H.264, ~40–50% меньше при том же качестве
            AVVideoWidthKey: pxW,
            AVVideoHeightKey: pxH,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: targetBitrate,
                AVVideoExpectedSourceFrameRateKey: f,
                AVVideoMaxKeyFrameIntervalKey: f,            // keyframe раз в секунду: passthrough-трим в редакторе режет по ключевым кадрам, GOP 4с давал погрешность реза до 4с
                AVVideoAllowFrameReorderingKey: true,        // B-кадры — выше эффективность сжатия
            ],
        ]
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vIn.expectsMediaDataInRealTime = true
        if w.canAdd(vIn) { w.add(vIn) }
        videoInput = vIn

        let channels = Settings.shared.recordAudioMono ? 1 : 2
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: channels,
            AVSampleRateKey: 48000,
        ]
        if systemAudio {
            let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            aIn.expectsMediaDataInRealTime = true
            if w.canAdd(aIn) { w.add(aIn) }
            audioInput = aIn
        }
        if mic {
            let mIn = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            mIn.expectsMediaDataInRealTime = true
            if w.canAdd(mIn) { w.add(mIn) }
            micInput = mIn
        }

        writer = w
        url = outURL
    }

    private func resetTimingState() {
        sessionStarted = false
        timeOffset = .zero
        lastVideoPTS = .zero
        resuming = false
        writeFailed = false
    }

    private func cleanup() {
        stream = nil
        writer = nil
        videoInput = nil
        audioInput = nil
        micInput = nil
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = NSLocalizedString("yyyy-MM-dd 'в' HH.mm.ss", comment: "")
        return f.string(from: Date())
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard CMSampleBufferDataIsReady(sampleBuffer), writer != nil else { return }
        switch type {
        case .screen: handleVideo(sampleBuffer)
        case .audio: handleAudio(sampleBuffer, input: audioInput)
        default:
            if #available(macOS 15.0, *), type == .microphone { handleAudio(sampleBuffer, input: micInput) }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Стрим умер (отключили дисплей, сменилось разрешение, система забрала захват).
        // Финализируем то, что успели записать, и сообщаем наверх — иначе UI продолжит
        // показывать «идёт запись», а файл молча оборвётся.
        Task { [weak self] in
            guard let self else { return }
            let url = await self.stop()   // транзишн-guard внутри: при гонке с ручным stop ничего не делает
            await MainActor.run {
                self.onError?(error.localizedDescription)
                self.onStopped?(url)
            }
        }
    }

    // MARK: - Sample handling (on `queue`)

    private func handleVideo(_ sb: CMSampleBuffer) {
        guard let writer = writer, let input = videoInput else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        // Статус кадра: в файл пишем только .complete, но PTS учитываем у ВСЕХ кадров
        // (на статичном экране SCK шлёт .idle — если их игнорировать, lastVideoPTS
        // устаревает и resume после паузы вырезает из таймлайна весь статичный период,
        // ломая монотонность PTS относительно уже записанного звука).
        var isComplete = true
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = arr.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw), status != .complete {
            isComplete = false
        }

        if !sessionStarted {
            guard isComplete else { return }   // сессию начинаем только с полного кадра
            guard writer.startWriting() else {
                // Диск полон / папка недоступна: сообщаем один раз и наверх,
                // иначе вся «запись» молча уйдёт в никуда.
                if !writeFailed {
                    writeFailed = true
                    let msg = writer.error?.localizedDescription
                        ?? NSLocalizedString("Не удалось начать запись файла", comment: "")
                    DispatchQueue.main.async { [weak self] in self?.onError?(msg) }
                }
                return
            }
            writer.startSession(atSourceTime: pts)
            sessionStarted = true
            lastVideoPTS = pts
        }
        if currentState == .paused { return }   // PTS паузы не учитываем — её и вырезаем
        if resuming {
            // Смещаем так, чтобы первый кадр после паузы шёл на один кадр позже
            // последнего до паузы (строго возрастающие PTS, без «дыры»).
            let frameDur = CMTime(value: 1, timescale: CMTimeScale(fps))
            timeOffset = timeOffset + (pts - lastVideoPTS - frameDur)
            resuming = false
        }
        lastVideoPTS = pts
        guard isComplete, input.isReadyForMoreMediaData else { return }
        if let adj = Self.adjustTiming(sb, by: timeOffset) { input.append(adj) }
    }

    private func handleAudio(_ sb: CMSampleBuffer, input: AVAssetWriterInput?) {
        // Пока не пришёл первый видеокадр после возобновления, timeOffset ещё не пересчитан —
        // дропаем аудио, чтобы не было рассинхрона на границе паузы.
        guard sessionStarted, currentState == .recording, !resuming,
              let input = input, input.isReadyForMoreMediaData else { return }
        if let adj = Self.adjustTiming(sb, by: timeOffset) { input.append(adj) }
    }

    /// Сдвиг всех таймингов буфера на offset (убирает паузы из таймлайна).
    private static func adjustTiming(_ sb: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        if offset == .zero { return sb }
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return sb }
        var info = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: count, arrayToFill: &info, entriesNeededOut: &count)
        for i in 0..<count {
            info[i].presentationTimeStamp = info[i].presentationTimeStamp - offset
            if info[i].decodeTimeStamp != .invalid {
                info[i].decodeTimeStamp = info[i].decodeTimeStamp - offset
            }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sb,
                                              sampleTimingEntryCount: count, sampleTimingArray: &info,
                                              sampleBufferOut: &out)
        return out
    }
}
