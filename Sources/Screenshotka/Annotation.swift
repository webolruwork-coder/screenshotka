import AppKit

/// Инструменты редактора.
enum ToolKind: String, CaseIterable {
    case arrow, line, rect, ellipse, pen, highlight, blur, text

    /// Имя SF Symbol для кнопки в тулбаре.
    var symbol: String {
        switch self {
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .rect: return "rectangle"
        case .ellipse: return "circle"
        case .pen: return "scribble.variable"
        case .highlight: return "highlighter"
        case .blur: return "mosaic"
        case .text: return "textformat"
        }
    }
    var tooltip: String {
        switch self {
        case .arrow: return NSLocalizedString("Стрелка", comment: "")
        case .line: return NSLocalizedString("Линия", comment: "")
        case .rect: return NSLocalizedString("Прямоугольник", comment: "")
        case .ellipse: return NSLocalizedString("Овал", comment: "")
        case .pen: return NSLocalizedString("Карандаш", comment: "")
        case .highlight: return NSLocalizedString("Маркер", comment: "")
        case .blur: return NSLocalizedString("Размытие", comment: "")
        case .text: return NSLocalizedString("Текст", comment: "")
        }
    }
}

/// Одна аннотация. Координаты — в пикселях изображения, origin сверху-слева.
final class Annotation {
    let kind: ToolKind
    var color: NSColor
    var lineWidth: CGFloat
    var start: CGPoint = .zero
    var end: CGPoint = .zero
    var points: [CGPoint] = []      // для карандаша
    var text: String = ""
    var fontSize: CGFloat = 28

    init(kind: ToolKind, color: NSColor, lineWidth: CGFloat) {
        self.kind = kind
        self.color = color
        self.lineWidth = lineWidth
    }

    private var normalizedRect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    /// Рисует аннотацию в текущем (перевёрнутом, origin сверху-слева) графическом контексте.
    func draw(pixelated: NSImage?) {
        color.setStroke()
        color.setFill()

        switch kind {
        case .line:
            stroke(path: linePath(start, end))
        case .arrow:
            drawArrow()
        case .rect:
            let p = NSBezierPath(rect: normalizedRect); p.lineWidth = lineWidth; p.stroke()
        case .ellipse:
            let p = NSBezierPath(ovalIn: normalizedRect); p.lineWidth = lineWidth; p.stroke()
        case .pen:
            guard points.count > 1 else { break }
            let p = NSBezierPath(); p.move(to: points[0])
            for pt in points.dropFirst() { p.line(to: pt) }
            p.lineWidth = lineWidth; p.lineJoinStyle = .round; p.lineCapStyle = .round; p.stroke()
        case .highlight:
            let r = normalizedRect
            color.withAlphaComponent(0.35).setFill()
            NSBezierPath(rect: r).fill()
        case .blur:
            guard let px = pixelated else { break }
            let r = normalizedRect
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: r).addClip()
            px.draw(in: CGRect(origin: .zero, size: px.size))
            NSGraphicsContext.restoreGraphicsState()
        case .text:
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: fontSize),
                .foregroundColor: color,
            ]
            (text as NSString).draw(at: start, withAttributes: attrs)
        }
    }

    private func stroke(path: NSBezierPath) {
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.stroke()
    }

    private func linePath(_ a: CGPoint, _ b: CGPoint) -> NSBezierPath {
        let p = NSBezierPath(); p.move(to: a); p.line(to: b); return p
    }

    private func drawArrow() {
        let p = linePath(start, end)
        p.lineWidth = lineWidth
        p.lineCapStyle = .round
        p.stroke()

        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLen = max(12, lineWidth * 4)
        let spread = CGFloat.pi / 7
        let p1 = CGPoint(x: end.x - headLen * cos(angle - spread),
                         y: end.y - headLen * sin(angle - spread))
        let p2 = CGPoint(x: end.x - headLen * cos(angle + spread),
                         y: end.y - headLen * sin(angle + spread))
        let head = NSBezierPath()
        head.move(to: end); head.line(to: p1); head.line(to: p2); head.close()
        head.fill()
    }
}
