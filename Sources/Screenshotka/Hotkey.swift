import AppKit
import Carbon.HIToolbox

enum HotkeyAction: String, CaseIterable {
    case captureArea
    case captureAreaCopy
    case captureAreaSave
    case captureAreaAnnotate
    case captureAreaPin
    case captureWindow
    case captureFullscreen
    case recordVideo
    case recordVideoCopy

    var title: String {
        switch self {
        case .captureArea: return NSLocalizedString("Снять область", comment: "")
        case .captureAreaCopy: return NSLocalizedString("Снять область и скопировать", comment: "")
        case .captureAreaSave: return NSLocalizedString("Снять область и сохранить", comment: "")
        case .captureAreaAnnotate: return NSLocalizedString("Снять область и открыть редактор", comment: "")
        case .captureAreaPin: return NSLocalizedString("Снять область и закрепить", comment: "")
        case .captureWindow: return NSLocalizedString("Снять окно", comment: "")
        case .captureFullscreen: return NSLocalizedString("Весь экран", comment: "")
        case .recordVideo: return NSLocalizedString("Записать видео / остановить", comment: "")
        case .recordVideoCopy: return NSLocalizedString("Записать видео и скопировать", comment: "")
        }
    }

    var section: String {
        switch self {
        case .captureArea, .captureAreaCopy, .captureAreaSave, .captureAreaAnnotate, .captureAreaPin, .captureWindow, .captureFullscreen:
            return NSLocalizedString("Скриншоты", comment: "")
        case .recordVideo, .recordVideoCopy: return NSLocalizedString("Запись экрана", comment: "")
        }
    }

    var defaults: HotkeyShortcut {
        let ctrlShift = Int(controlKey | shiftKey)
        switch self {
        case .captureArea: return HotkeyShortcut(keyCode: kVK_ANSI_4, modifiers: ctrlShift)
        case .captureAreaCopy, .captureAreaSave, .captureAreaAnnotate, .captureAreaPin:
            return HotkeyShortcut(keyCode: 0, modifiers: 0)
        case .captureWindow: return HotkeyShortcut(keyCode: kVK_ANSI_5, modifiers: ctrlShift)
        case .captureFullscreen: return HotkeyShortcut(keyCode: kVK_ANSI_3, modifiers: ctrlShift)
        case .recordVideo: return HotkeyShortcut(keyCode: kVK_ANSI_6, modifiers: ctrlShift)
        case .recordVideoCopy: return HotkeyShortcut(keyCode: 0, modifiers: 0)
        }
    }
}

struct HotkeyShortcut: Equatable {
    let keyCode: Int
    let modifiers: Int

    var isUsable: Bool { modifiers != 0 }

    var displayString: String {
        guard isUsable else { return NSLocalizedString("Записать хоткей", comment: "") }
        let mods = Self.modifierDisplay(modifiers)
        let key = Self.keyDisplay(keyCode)
        return mods + key
    }

    static func from(event: NSEvent) -> HotkeyShortcut? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods = 0
        if flags.contains(.command) { mods |= Int(cmdKey) }
        if flags.contains(.option) { mods |= Int(optionKey) }
        if flags.contains(.control) { mods |= Int(controlKey) }
        if flags.contains(.shift) { mods |= Int(shiftKey) }
        guard mods != 0 else { return nil }
        return HotkeyShortcut(keyCode: Int(event.keyCode), modifiers: mods)
    }

    static func modifierDisplay(_ modifiers: Int) -> String {
        var text = ""
        if modifiers & Int(controlKey) != 0 { text += "⌃" }
        if modifiers & Int(optionKey) != 0 { text += "⌥" }
        if modifiers & Int(shiftKey) != 0 { text += "⇧" }
        if modifiers & Int(cmdKey) != 0 { text += "⌘" }
        return text
    }

    static func keyDisplay(_ keyCode: Int) -> String {
        switch keyCode {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_Return: return "↩"
        case kVK_Escape: return "Esc"
        case kVK_Space: return "Space"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default: return "Key \(keyCode)"
        }
    }
}

extension Notification.Name {
    static let screenshotkaHotkeysChanged = Notification.Name("screenshotkaHotkeysChanged")
}
