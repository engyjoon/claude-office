import AppKit
import OfficeCore
import OfficeStage
import SpriteKit

/// 말풍선·상태 칩·아이콘 하나. 도형이 바뀔 때만 다시 만들고, 매 프레임에는 위치·크기·투명도만 바꿉니다.
final class OverlayNode: SKNode {
    private var shownShapes: [ArtShape] = []

    func apply(_ item: OverlayItem, sceneHeight: Double) {
        if item.shapes != shownShapes {
            shownShapes = item.shapes
            removeAllChildren()
            addChild(ArtNodes.node(for: item.shapes, colors: nil) { label, shape in ArtNodes.fit(label, in: item, shape: shape) })
        }
        position = CGPoint(x: item.origin.x, y: sceneHeight - item.origin.y)
        setScale(item.scale)
        alpha = item.opacity
    }
}

/// 렌더러와 무관한 도형(ArtShape)을 SpriteKit 노드로
enum ArtNodes {
    /// 말풍선 글자가 어림한 폭보다 넓게 그려지면 상자 안에 들어오도록 가로로 살짝 줄입니다
    static func fit(_ label: SKLabelNode, in item: OverlayItem, shape: ArtShape) {
        guard item.kind == .bubble || item.kind == .pill,
              case .text(let string, _, let size, let bold, _, _) = shape.geometry else { return }
        let estimated = TextMetrics.width(string, size: size, bold: bold)
        let actual = label.frame.width
        if actual > estimated + 0.5, actual > 0 {
            label.xScale = estimated / actual
        }
    }

    /// 도형 묶음 → 노드 (노드 안 좌표 `(x, -y)`). 글자가 아닌 도형은 이어진 것끼리 비트맵 한 장으로 구워 스프라이트로 만들고
    /// (`ShapeBaker`, M6(1)), 글자는 SKLabelNode로 둡니다. 그리는 순서는 도형 순서 그대로입니다.
    /// - Parameter onLabel: 글자 노드를 만든 뒤 부름 (말풍선 글자 폭 맞추기)
    static func node(
        for shapes: [ArtShape], colors: CharacterArt.Colors?, clip: CGRect? = nil, onLabel: ((SKLabelNode, ArtShape) -> Void)? = nil
    ) -> SKNode {
        var parts: [SKNode] = []
        var run: [ArtShape] = []
        func flush() {
            guard !run.isEmpty else { return }
            parts.append(ShapeBaker.node(for: run, colors: colors, clip: clip))
            run.removeAll()
        }
        for shape in shapes {
            guard case .text = shape.geometry else {
                run.append(shape)
                continue
            }
            flush()
            let node = node(for: shape, colors: colors, transform: local)
            if let label = node as? SKLabelNode { onLabel?(label, shape) }
            parts.append(node)
        }
        flush()
        if parts.count == 1 { return parts[0] }
        let container = SKNode()
        for part in parts { container.addChild(part) }
        return container
    }

    /// 그림 데이터(y 아래로 증가)를 노드 안의 좌표(y 위로 증가)로
    static let local: (MapPoint) -> CGPoint = { CGPoint(x: $0.x, y: -$0.y) }

    /// 굽지 않은 도형 노드 묶음 (매 프레임 바뀌는 움직이는 가구용)
    static func unbakedNode(for shapes: [ArtShape], colors: CharacterArt.Colors?, transform: @escaping (MapPoint) -> CGPoint) -> SKNode {
        let container = SKNode()
        for shape in shapes {
            container.addChild(node(for: shape, colors: colors, transform: transform))
        }
        return container
    }

    static func node(for shape: ArtShape, colors: CharacterArt.Colors?, transform: (MapPoint) -> CGPoint) -> SKNode {
        if case .text(let string, let at, let size, let bold, let anchor, let baseline) = shape.geometry {
            let label = SKLabelNode(text: string)
            label.fontName = bold ? "AppleSDGothicNeo-Bold" : "AppleSDGothicNeo-Regular"
            label.fontSize = size
            label.fontColor = shape.fill.map { color($0, colors) } ?? .black
            label.verticalAlignmentMode = .baseline
            switch anchor {
            case .start: label.horizontalAlignmentMode = .left
            case .middle: label.horizontalAlignmentMode = .center
            case .end: label.horizontalAlignmentMode = .right
            }
            var position = transform(at)
            if baseline == .central {
                // SKLabelNode의 .center는 글꼴의 위아래 여백까지 포함한 줄 높이의 가운데라서 글자가 위로 떠 보입니다.
                // 실제 글자 모양(한글과 대문자)의 높이 가운데를 기준점에 맞춥니다.
                position.y -= inkMidline(fontName: label.fontName ?? "", size: size)
            }
            label.position = position
            label.alpha = shape.opacity
            return label
        }
        let shapePath = path(shape.geometry, transform: transform)
        if shape.dash > 0, let stroke = shape.stroke {
            // SKShapeNode에는 점선이 없어서, 채우기와 점선 테두리를 따로 그립니다
            let container = SKNode()
            let fill = SKShapeNode(path: shapePath)
            fill.fillColor = shape.fill.map { color($0, colors) } ?? .clear
            fill.strokeColor = .clear
            fill.lineWidth = 0
            container.addChild(fill)
            let dashed = SKShapeNode(path: shapePath.copy(dashingWithPhase: 0, lengths: [shape.dash, shape.dash]))
            dashed.fillColor = .clear
            dashed.strokeColor = color(stroke, colors)
            dashed.lineWidth = shape.lineWidth
            dashed.lineCap = .round
            dashed.isAntialiased = true
            container.addChild(dashed)
            container.alpha = shape.opacity
            return container
        }
        let node = SKShapeNode(path: shapePath)
        node.fillColor = shape.fill.map { color($0, colors) } ?? .clear
        if let stroke = shape.stroke {
            node.strokeColor = color(stroke, colors)
            node.lineWidth = shape.lineWidth
        } else {
            node.strokeColor = .clear
            node.lineWidth = 0
        }
        node.lineJoin = .round
        node.lineCap = .round
        node.isAntialiased = true
        node.alpha = shape.opacity
        return node
    }

    private static var midlineCache: [String: CGFloat] = [:]

    /// 바닥선에서 글자 높이 가운데까지의 거리. 내림 획이 없는 "가H"의 글리프 경계로 잽니다.
    static func inkMidline(fontName: String, size: CGFloat) -> CGFloat {
        let key = "\(fontName)@\(size)"
        if let cached = midlineCache[key] { return cached }
        let font = NSFont(name: fontName, size: size) ?? NSFont.systemFont(ofSize: size)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "가H", attributes: [.font: font]))
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let midline = bounds.midY
        midlineCache[key] = midline
        return midline
    }

    static func color(_ paint: Paint, _ colors: CharacterArt.Colors?) -> NSColor {
        SVGRenderer.resolve(paint, colors: colors).skColor
    }

    static func path(_ geometry: ArtShape.Geometry, transform: (MapPoint) -> CGPoint) -> CGPath {
        let path = CGMutablePath()
        switch geometry {
        case .path(let commands):
            for command in commands {
                switch command {
                case .move(let p): path.move(to: transform(p))
                case .line(let p): path.addLine(to: transform(p))
                case .quad(let c, let p): path.addQuadCurve(to: transform(p), control: transform(c))
                case .cubic(let c1, let c2, let p): path.addCurve(to: transform(p), control1: transform(c1), control2: transform(c2))
                case .close: path.closeSubpath()
                }
            }
        case .circle(let center, let radius):
            path.addEllipse(in: box(center: center, rx: radius, ry: radius, transform: transform))
        case .ellipse(let center, let rx, let ry):
            path.addEllipse(in: box(center: center, rx: rx, ry: ry, transform: transform))
        case .rect(let rect, let radius):
            let a = transform(MapPoint(rect.x, rect.y))
            let b = transform(MapPoint(rect.maxX, rect.maxY))
            let frame = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
            let corner = max(0, min(radius, frame.width / 2, frame.height / 2))
            if corner > 0 {
                path.addRoundedRect(in: frame, cornerWidth: corner, cornerHeight: corner)
            } else {
                path.addRect(frame)
            }
        case .text:
            break
        }
        return path
    }

    private static func box(center: MapPoint, rx: Double, ry: Double, transform: (MapPoint) -> CGPoint) -> CGRect {
        let c = transform(center)
        return CGRect(x: c.x - rx, y: c.y - ry, width: rx * 2, height: ry * 2)
    }
}

extension ArtColor {
    var skColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}
