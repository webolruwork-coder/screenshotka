import AppKit

/// Единая дизайн-система: семантические токены, шкалы отступов/радиусов, тени.
/// Тёмная минималистичная тема в духе нативного macOS.
enum Theme {

    // MARK: - Цвета (семантические токены)

    /// Акцент берём из системной настройки пользователя — максимально нативно.
    static var accent: NSColor { .controlAccentColor }

    /// Скрим под выделением области. 45% — изолирует фон, но виден контент (правило 40–60%).
    static let scrim = NSColor(white: 0.0, alpha: 0.45)

    /// Поверхности (плашки, тулбар).
    static let surface = NSColor(white: 0.14, alpha: 0.96)
    static let surfaceElevated = NSColor(white: 0.18, alpha: 0.98)
    static let surfaceStroke = NSColor(white: 1.0, alpha: 0.10)

    /// Текст: primary ≥ 4.5:1, secondary ≥ 3:1 на тёмной поверхности.
    static let textPrimary = NSColor(white: 0.97, alpha: 1.0)
    static let textSecondary = NSColor(white: 0.66, alpha: 1.0)

    static let destructive = NSColor.systemRed

    /// Подсветка наведения/выбора на кнопках.
    static var hoverFill: NSColor { accent.withAlphaComponent(0.16) }
    static var selectedFill: NSColor { accent.withAlphaComponent(0.26) }

    // Обратная совместимость со старыми именами.
    static var dimColor: NSColor { scrim }
    static var panelBackground: NSColor { surface }
    static var panelStroke: NSColor { surfaceStroke }
    static var toolbarBackground: NSColor { surfaceElevated }

    // MARK: - Шкала отступов (4/8 pt)

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
    }

    // MARK: - Радиусы

    enum Radius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 10
        static let lg: CGFloat = 14
    }

    // Обратная совместимость.
    static let corner: CGFloat = Radius.lg
    static let badgeCorner: CGFloat = Radius.sm

    // MARK: - Тени (единая «высота»)

    static func shadow() -> NSShadow {
        let s = NSShadow()
        s.shadowColor = NSColor(white: 0, alpha: 0.45)
        s.shadowBlurRadius = 18
        s.shadowOffset = NSSize(width: 0, height: -4)
        return s
    }

    // MARK: - Движение

    /// Уважать настройку «Уменьшить движение».
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Длительность анимации с учётом reduce-motion (0 — мгновенно).
    static func duration(_ value: TimeInterval) -> TimeInterval {
        reduceMotion ? 0 : value
    }
}
