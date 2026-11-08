import Foundation

/// 색 (0xRRGGBB + 불투명도)
public struct ArtColor: Hashable, Sendable {
    public var rgb: UInt32
    public var alpha: Double

    public init(_ rgb: UInt32, alpha: Double = 1) {
        self.rgb = rgb
        self.alpha = alpha
    }

    public var red: Double { Double((rgb >> 16) & 0xFF) / 255 }
    public var green: Double { Double((rgb >> 8) & 0xFF) / 255 }
    public var blue: Double { Double(rgb & 0xFF) / 255 }

    public var hex: String { String(format: "#%06X", rgb) }
}

/// 사무실 공통 색 (설계서 §9.2 주간 팔레트, 미리보기와 같은 값). 야간 모드는 M6에서 추가합니다.
public enum Swatch: String, Hashable, Sendable, CaseIterable {
    case ink, shadow, wall, wallTrim, baseboard, floor, floorLine
    case wood, woodTop, woodDark, metal, metalDot, screenGlow
    case plate, plateInk, sky, sky2, cloud
    case rugA, rugB, rugC, rugD, drop, blush, mouth, pot, board, rack, rackDark, white
    case mint, peach, butter, lavender, skyBlue, pink, alert, check

    public var color: ArtColor {
        switch self {
        case .ink: ArtColor(0x3A3247)
        case .shadow: ArtColor(0x3A3247, alpha: 0.16)
        case .wall: ArtColor(0xE7EDEF)
        case .wallTrim: ArtColor(0xD3DCE0)
        case .baseboard: ArtColor(0xC9C2D6)
        case .floor: ArtColor(0xF1E6D6)
        case .floorLine: ArtColor(0xE7D8C3)
        case .wood: ArtColor(0xD9B48F)
        case .woodTop: ArtColor(0xE8C9A6)
        case .woodDark: ArtColor(0xB58C66)
        case .metal: ArtColor(0xB9BFD0)
        case .metalDot: ArtColor(0xEEF0F6)
        case .screenGlow: ArtColor(0x78E1C3, alpha: 0.42)
        case .plate: ArtColor(0xFFF8EC)
        case .plateInk: ArtColor(0x5A4E66)
        case .sky: ArtColor(0xBFE0F5)
        case .sky2: ArtColor(0xDDEFFA)
        case .cloud, .white: ArtColor(0xFFFFFF)
        case .rugA: ArtColor(0xC3E7DC)
        case .rugB: ArtColor(0xF8D4C5)
        case .rugC: ArtColor(0xDDD6F3)
        case .rugD: ArtColor(0xF8EBC0)
        case .drop: ArtColor(0x8CC8EE)
        case .blush: ArtColor(0xF48C8C)
        case .mouth: ArtColor(0x9A4E5E)
        case .pot: ArtColor(0xE9A88A)
        case .board: ArtColor(0xFFFFFF)
        case .rack: ArtColor(0x5B5670)
        case .rackDark: ArtColor(0x48435C)
        case .mint: ArtColor(0x9FD8C7)
        case .peach: ArtColor(0xF6B9A0)
        case .butter: ArtColor(0xF7DE8B)
        case .lavender: ArtColor(0xC7BCEB)
        case .skyBlue: ArtColor(0xA9D3F0)
        case .pink: ArtColor(0xF4A3B4)
        case .alert: ArtColor(0xF08A6C)
        case .check: ArtColor(0x2C8A78)
        }
    }

    public static let teamRugs: [Swatch] = [.rugA, .rugB, .rugC, .rugD]
    public static let teamColors: [Swatch] = [.mint, .peach, .lavender, .butter]
}

/// 칠할 색. 캐릭터 부위 색은 직원 외형에 따라 정해집니다.
public enum Paint: Hashable, Sendable {
    case swatch(Swatch)
    case color(ArtColor)
    case skin, hair, top, pants
}

public enum TextAnchor: String, Hashable, Sendable {
    case start, middle, end
}

/// 글자의 세로 기준. `alphabetic`은 y가 글자 바닥선, `central`은 y가 글자 높이의 가운데입니다.
/// 명패처럼 상자 안에 넣는 글자는 `central`로 두면 글꼴마다 다른 바닥선 위치와 상관없이 가운데에 섭니다.
public enum TextBaseline: String, Hashable, Sendable {
    case alphabetic, central
}

/// 렌더러와 무관한 도형 한 개 (좌표는 y가 아래로 증가)
public struct ArtShape: Hashable, Sendable {
    public enum Geometry: Hashable, Sendable {
        case path([PathCommand])
        case circle(center: MapPoint, radius: Double)
        case ellipse(center: MapPoint, rx: Double, ry: Double)
        case rect(MapRect, radius: Double)
        case text(String, at: MapPoint, size: Double, bold: Bool, anchor: TextAnchor, baseline: TextBaseline)
    }

    public var geometry: Geometry
    public var fill: Paint?
    public var stroke: Paint?
    public var lineWidth: Double
    public var opacity: Double

    public init(_ geometry: Geometry, fill: Paint? = nil, stroke: Paint? = nil, lineWidth: Double = 1.8, opacity: Double = 1) {
        self.geometry = geometry
        self.fill = fill
        self.stroke = stroke
        self.lineWidth = lineWidth
        self.opacity = opacity
    }

    // 짧게 쓰기 위한 도우미 (미리보기 SVG의 class="o" = 잉크 외곽선)
    public static func path(_ d: String, fill: Paint? = nil, outline: Bool = true, width: Double = 1.8, stroke: Paint? = nil, opacity: Double = 1) -> ArtShape {
        ArtShape(.path(VectorPath.parse(d)), fill: fill, stroke: stroke ?? (outline ? .swatch(.ink) : nil), lineWidth: width, opacity: opacity)
    }

    public static func line(_ d: String, width: Double = 2, color: Paint = .swatch(.ink), opacity: Double = 1) -> ArtShape {
        ArtShape(.path(VectorPath.parse(d)), fill: nil, stroke: color, lineWidth: width, opacity: opacity)
    }

    public static func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, r: Double = 0, fill: Paint, outline: Bool = true, width: Double = 1.8, opacity: Double = 1) -> ArtShape {
        ArtShape(.rect(MapRect(x, y, w, h), radius: r), fill: fill, stroke: outline ? .swatch(.ink) : nil, lineWidth: width, opacity: opacity)
    }

    public static func circle(_ x: Double, _ y: Double, _ r: Double, fill: Paint, outline: Bool = true, width: Double = 1.8, opacity: Double = 1) -> ArtShape {
        ArtShape(.circle(center: MapPoint(x, y), radius: r), fill: fill, stroke: outline ? .swatch(.ink) : nil, lineWidth: width, opacity: opacity)
    }

    public static func ellipse(_ x: Double, _ y: Double, _ rx: Double, _ ry: Double, fill: Paint, outline: Bool = false, width: Double = 1.8, opacity: Double = 1) -> ArtShape {
        ArtShape(.ellipse(center: MapPoint(x, y), rx: rx, ry: ry), fill: fill, stroke: outline ? .swatch(.ink) : nil, lineWidth: width, opacity: opacity)
    }

    public static func text(_ string: String, _ x: Double, _ y: Double, size: Double, bold: Bool = false, color: Paint = .swatch(.plateInk), anchor: TextAnchor = .middle, baseline: TextBaseline = .alphabetic) -> ArtShape {
        ArtShape(.text(string, at: MapPoint(x, y), size: size, bold: bold, anchor: anchor, baseline: baseline), fill: color)
    }

    /// 도형 전체를 옮기거나 키웁니다 (미리보기의 translate/scale)
    public func transformed(scale: Double = 1, offset: MapPoint = .zero) -> ArtShape {
        func t(_ p: MapPoint) -> MapPoint { MapPoint(p.x * scale + offset.x, p.y * scale + offset.y) }
        var copy = self
        switch geometry {
        case .path(let commands): copy.geometry = .path(VectorPath.transformed(commands, t))
        case .circle(let c, let r): copy.geometry = .circle(center: t(c), radius: r * scale)
        case .ellipse(let c, let rx, let ry): copy.geometry = .ellipse(center: t(c), rx: rx * scale, ry: ry * scale)
        case .rect(let rect, let radius):
            copy.geometry = .rect(MapRect(rect.x * scale + offset.x, rect.y * scale + offset.y, rect.width * scale, rect.height * scale), radius: radius * scale)
        case .text(let s, let at, let size, let bold, let anchor, let baseline):
            copy.geometry = .text(s, at: t(at), size: size * scale, bold: bold, anchor: anchor, baseline: baseline)
        }
        if scale != 1 { copy.lineWidth *= scale }
        return copy
    }
}

extension Array where Element == ArtShape {
    public func transformed(scale: Double = 1, offset: MapPoint = .zero) -> [ArtShape] {
        map { $0.transformed(scale: scale, offset: offset) }
    }
}

/// 깊이(발 위치 y)가 있는 도형 묶음. 렌더러는 깊이 순서로 직원과 함께 그립니다.
/// 깊이가 `-.infinity`이면 바닥·벽처럼 항상 맨 뒤입니다.
public struct ArtLayer: Hashable, Sendable {
    public var name: String
    public var depth: Double
    public var shapes: [ArtShape]

    public init(_ name: String, depth: Double, _ shapes: [ArtShape]) {
        self.name = name
        self.depth = depth
        self.shapes = shapes
    }
}
