import AppKit

/// Формат файла скриншота.
enum ScreenshotFormat: String, CaseIterable {
    case png, jpeg, heif
    var ext: String { self == .png ? "png" : (self == .jpeg ? "jpg" : "heic") }
    var isLossy: Bool { self != .png }
    var title: String {
        switch self {
        case .png:  return NSLocalizedString("PNG — без потерь", comment: "")
        case .jpeg: return NSLocalizedString("JPEG", comment: "")
        case .heif: return NSLocalizedString("HEIF (HEIC)", comment: "")
        }
    }
}

/// Хранилище пользовательских настроек поверх UserDefaults.
final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    private enum Keys {
        static let saveFolder = "saveFolderBookmark"
        static let copyToClipboard = "copyToClipboard"
        static let showPreview = "showPreview"
        static let playSound = "playSound"
        static let autoSave = "autoSave"
        static let freezeScreen = "freezeScreen"
        static let format = "imageFormat"
        static let quality = "screenshotQuality"
        static let captureCursor = "captureCursor"
        static let windowShadow = "screenshotWindowShadow"
        static let scale1x = "screenshotScale1x"
    }

    init() {
        d.register(defaults: [
            Keys.copyToClipboard: true,
            Keys.showPreview: true,
            Keys.playSound: true,
            Keys.autoSave: true,
            Keys.freezeScreen: false,   // как в macOS: экран не «замораживаем» (подмена кадра = мерцание)
            Keys.format: "png",
        ])
    }

    /// Заморозка экрана на время выделения области (как в CleanShot).
    var freezeScreen: Bool {
        get { d.bool(forKey: Keys.freezeScreen) }
        set { d.set(newValue, forKey: Keys.freezeScreen) }
    }

    // MARK: - Скриншоты

    /// Формат файла скриншота (по умолчанию PNG — без потерь).
    var screenshotFormat: ScreenshotFormat {
        get { ScreenshotFormat(rawValue: d.string(forKey: Keys.format) ?? "png") ?? .png }
        set { d.set(newValue.rawValue, forKey: Keys.format) }
    }
    /// Качество для JPEG/HEIF (0.3…1.0). Для PNG не используется.
    var screenshotQuality: Double {
        get { d.object(forKey: Keys.quality) != nil ? d.double(forKey: Keys.quality) : 0.9 }
        set { d.set(newValue, forKey: Keys.quality) }
    }
    /// Захватывать указатель мыши в снимок.
    var captureCursor: Bool {
        get { d.bool(forKey: Keys.captureCursor) }
        set { d.set(newValue, forKey: Keys.captureCursor) }
    }
    /// Сохранять тень окна при режиме «Снять окно».
    var screenshotWindowShadow: Bool {
        get { d.bool(forKey: Keys.windowShadow) }
        set { d.set(newValue, forKey: Keys.windowShadow) }
    }
    /// Уменьшать снимок до 1× (по умолчанию — полное Retina-разрешение 2×).
    var screenshotScaleTo1x: Bool {
        get { d.bool(forKey: Keys.scale1x) }
        set { d.set(newValue, forKey: Keys.scale1x) }
    }

    // MARK: - Видео
    var micEnabled: Bool {
        get { d.bool(forKey: "micEnabled") }
        set { d.set(newValue, forKey: "micEnabled") }
    }
    var systemAudioEnabled: Bool {
        get { d.object(forKey: "systemAudioEnabled") != nil ? d.bool(forKey: "systemAudioEnabled") : true }
        set { d.set(newValue, forKey: "systemAudioEnabled") }
    }
    var showCursorInVideo: Bool {
        get { d.object(forKey: "showCursorInVideo") != nil ? d.bool(forKey: "showCursorInVideo") : true }
        set { d.set(newValue, forKey: "showCursorInVideo") }
    }
    var videoFPS: Int {
        get { d.object(forKey: "videoFPS") != nil ? d.integer(forKey: "videoFPS") : 30 }
        set { d.set(newValue, forKey: "videoFPS") }
    }
    /// uniqueID выбранного микрофона (nil — системный по умолчанию).
    var micDeviceID: String? {
        get { d.string(forKey: "micDeviceID") }
        set { d.set(newValue, forKey: "micDeviceID") }
    }
    var cameraEnabled: Bool {
        get { d.bool(forKey: "cameraEnabled") }
        set { d.set(newValue, forKey: "cameraEnabled") }
    }
    var cameraDeviceID: String? {
        get { d.string(forKey: "cameraDeviceID") }
        set { d.set(newValue, forKey: "cameraDeviceID") }
    }

    // MARK: - Видео: General
    private func boolDefault(_ key: String, _ def: Bool) -> Bool { d.object(forKey: key) != nil ? d.bool(forKey: key) : def }

    var showControlsWhileRecording: Bool { get { boolDefault("showControls", true) } set { d.set(newValue, forKey: "showControls") } }
    var displayRecordingTime: Bool { get { d.bool(forKey: "displayRecTime") } set { d.set(newValue, forKey: "displayRecTime") } }
    var scaleRetinaTo1x: Bool { get { d.bool(forKey: "scaleRetina1x") } set { d.set(newValue, forKey: "scaleRetina1x") } }
    var dndWhileRecording: Bool { get { d.bool(forKey: "dndWhileRec") } set { d.set(newValue, forKey: "dndWhileRec") } }
    var highlightClicks: Bool { get { d.bool(forKey: "highlightClicks") } set { d.set(newValue, forKey: "highlightClicks") } }
    var showKeystrokes: Bool { get { d.bool(forKey: "showKeystrokes") } set { d.set(newValue, forKey: "showKeystrokes") } }
    var rememberLastSelection: Bool { get { d.bool(forKey: "rememberLastSel") } set { d.set(newValue, forKey: "rememberLastSel") } }
    var dimScreenWhileRecording: Bool { get { boolDefault("dimWhileRec", true) } set { d.set(newValue, forKey: "dimWhileRec") } }
    var showCountdown: Bool { get { d.bool(forKey: "showCountdown") } set { d.set(newValue, forKey: "showCountdown") } }

    // MARK: - Видео: Video
    /// Максимальная высота кадра (0 — Original).
    var maxVideoHeight: Int { get { d.integer(forKey: "maxVideoHeight") } set { d.set(newValue, forKey: "maxVideoHeight") } }
    var recordAudioMono: Bool { get { d.bool(forKey: "recordAudioMono") } set { d.set(newValue, forKey: "recordAudioMono") } }
    var openAfterRecording: Bool { get { boolDefault("openAfterRec", true) } set { d.set(newValue, forKey: "openAfterRec") } }

    // MARK: - Хоткеи

    func hotkey(for action: HotkeyAction) -> HotkeyShortcut {
        let keyPrefix = "hotkey.\(action.rawValue)"
        guard d.object(forKey: "\(keyPrefix).keyCode") != nil,
              d.object(forKey: "\(keyPrefix).modifiers") != nil else {
            return action.defaults
        }
        return HotkeyShortcut(keyCode: d.integer(forKey: "\(keyPrefix).keyCode"),
                              modifiers: d.integer(forKey: "\(keyPrefix).modifiers"))
    }

    func setHotkey(_ shortcut: HotkeyShortcut, for action: HotkeyAction) {
        let keyPrefix = "hotkey.\(action.rawValue)"
        d.set(shortcut.keyCode, forKey: "\(keyPrefix).keyCode")
        d.set(shortcut.modifiers, forKey: "\(keyPrefix).modifiers")
        NotificationCenter.default.post(name: .screenshotkaHotkeysChanged, object: action)
    }

    func resetHotkeys() {
        for action in HotkeyAction.allCases {
            let keyPrefix = "hotkey.\(action.rawValue)"
            d.removeObject(forKey: "\(keyPrefix).keyCode")
            d.removeObject(forKey: "\(keyPrefix).modifiers")
        }
        NotificationCenter.default.post(name: .screenshotkaHotkeysChanged, object: nil)
    }

    /// Последняя область записи (для «Remember last selection»).
    var lastVideoRect: CGRect? {
        get {
            guard d.object(forKey: "lastVideoRectX") != nil else { return nil }
            return CGRect(x: d.double(forKey: "lastVideoRectX"), y: d.double(forKey: "lastVideoRectY"),
                          width: d.double(forKey: "lastVideoRectW"), height: d.double(forKey: "lastVideoRectH"))
        }
        set {
            if let r = newValue {
                d.set(r.minX, forKey: "lastVideoRectX"); d.set(r.minY, forKey: "lastVideoRectY")
                d.set(r.width, forKey: "lastVideoRectW"); d.set(r.height, forKey: "lastVideoRectH")
            }
        }
    }

    var autoSave: Bool {
        get { d.bool(forKey: Keys.autoSave) }
        set { d.set(newValue, forKey: Keys.autoSave) }
    }

    /// Последний инструмент редактора (по умолчанию — прямоугольник).
    var lastTool: ToolKind {
        get { ToolKind(rawValue: d.string(forKey: "lastTool") ?? "") ?? .rect }
        set { d.set(newValue.rawValue, forKey: "lastTool") }
    }

    /// Последний цвет (по умолчанию — красный).
    var lastColor: NSColor {
        get {
            if let data = d.data(forKey: "lastColor"),
               let c = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) {
                return c
            }
            return .systemRed
        }
        set {
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: newValue, requiringSecureCoding: true) {
                d.set(data, forKey: "lastColor")
            }
        }
    }

    /// Последняя толщина (индекс, по умолчанию — средняя).
    var lastWidthIndex: Int {
        get { d.object(forKey: "lastWidthIndex") != nil ? d.integer(forKey: "lastWidthIndex") : 1 }
        set { d.set(newValue, forKey: "lastWidthIndex") }
    }

    /// Запомненное положение плашки превью (глобальные координаты, origin окна).
    var previewOrigin: CGPoint? {
        get {
            guard d.object(forKey: "previewOriginX") != nil else { return nil }
            return CGPoint(x: d.double(forKey: "previewOriginX"), y: d.double(forKey: "previewOriginY"))
        }
        set {
            if let p = newValue {
                d.set(p.x, forKey: "previewOriginX")
                d.set(p.y, forKey: "previewOriginY")
            } else {
                d.removeObject(forKey: "previewOriginX")
                d.removeObject(forKey: "previewOriginY")
            }
        }
    }

    var copyToClipboard: Bool {
        get { d.bool(forKey: Keys.copyToClipboard) }
        set { d.set(newValue, forKey: Keys.copyToClipboard) }
    }

    var showPreview: Bool {
        get { d.bool(forKey: Keys.showPreview) }
        set { d.set(newValue, forKey: Keys.showPreview) }
    }

    var playSound: Bool {
        get { d.bool(forKey: Keys.playSound) }
        set { d.set(newValue, forKey: Keys.playSound) }
    }

    /// Папка сохранения по умолчанию — ~/Pictures/Screenshots.
    var saveFolder: URL {
        var stale = false
        if let data = d.data(forKey: Keys.saveFolder),
           let url = try? URL(resolvingBookmarkData: data, options: [],
                              relativeTo: nil, bookmarkDataIsStale: &stale) {
            return url
        }
        let pics = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let folder = pics.appendingPathComponent("Screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func setSaveFolder(_ url: URL) {
        if let data = try? url.bookmarkData(options: [],
                                            includingResourceValuesForKeys: nil, relativeTo: nil) {
            d.set(data, forKey: Keys.saveFolder)
        }
    }
}
