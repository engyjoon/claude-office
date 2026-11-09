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

/// 사무실 조명 (M6(6), 설계서 §9.2). 밤에는 벽·바닥·가구만 밤 팔레트로 칠하고, 직원·말풍선·칩·배지는 낮 색 그대로 둡니다
/// (실내 조명 아래 있는 것처럼).
public enum Lighting: String, Hashable, Sendable, CaseIterable {
    case day, night
}

/// 밤 팔레트 (M6(6) A안 "저녁 조명"). 낮 색을 받아 밤 색을 돌려줍니다.
///
/// - 벽·바닥·러그·하늘처럼 넓은 면은 손으로 고른 색(`overrides`)을 씁니다.
/// - 그 밖의 가구 색(나무, 금속, 의자, 소파, 가전 …)은 밤 톤(#232846)과 45% 섞습니다. 그림 데이터에 직접 쓴 색도 같은 규칙을 거칩니다.
/// - 명패·표지는 밝게 남겨 이름이 읽히게 하고, 화면 불빛(`screenGlow`)은 그대로 빛나게 둡니다.
/// - 그림 데이터 단계에서 `.swatch`를 `.color(밤색)`으로 바꿔 두므로, 앱의 굽기 캐시(도형이 키)가 낮·밤 텍스처를 저절로 구분합니다.
public enum NightPalette {
    public static let tone = ArtColor(0x232846)
    public static let mixAmount = 0.45

    /// 낮 색(RGB) → 밤 색
    static let overrides: [UInt32: UInt32] = [
        Swatch.wall.color.rgb: 0x3E4468,
        Swatch.wallTrim.color.rgb: 0x363C5E,
        Swatch.baseboard.color.rgb: 0x2C2D49,
        Swatch.floor.color.rgb: 0x5B4F63,
        Swatch.floorLine.color.rgb: 0x52465A,
        Swatch.plate.color.rgb: 0xEFE7DA,
        Swatch.plateInk.color.rgb: 0x4A3F57,
        Swatch.ink.color.rgb: 0x221D2C,
        Swatch.sky.color.rgb: 0x2E3A6A,
        Swatch.screenGlow.color.rgb: Swatch.screenGlow.color.rgb,
        Swatch.rugA.color.rgb: 0x3F5E66,
        Swatch.rugB.color.rgb: 0x6A4A5E,
        Swatch.rugC.color.rgb: 0x4A4472,
        Swatch.rugD.color.rgb: 0x66593F,
        0xD4E2F2: 0x3A4670,  // 안마 구역 러그
    ]

    public static func color(_ day: ArtColor) -> ArtColor {
        if let night = overrides[day.rgb] { return ArtColor(night, alpha: day.alpha) }
        return day.mixed(with: tone, amount: mixAmount)
    }

    /// 칠할 색을 밤 색으로. 직원 부위 색(피부·머리·옷)은 가구에 쓰지 않으므로 그대로 둡니다.
    public static func paint(_ paint: Paint) -> Paint {
        switch paint {
        case .swatch(let swatch): .color(color(swatch.color))
        case .color(let day): .color(color(day))
        case .skin, .hair, .top, .pants: paint
        }
    }
}

extension ArtColor {
    /// 조명에 맞춘 색 (낮이면 그대로)
    public func lit(_ lighting: Lighting) -> ArtColor {
        lighting == .night ? NightPalette.color(self) : self
    }

    /// 다른 색과 섞기 (amount 0 = 이 색, 1 = 다른 색). 불투명도는 이 색 그대로입니다.
    public func mixed(with other: ArtColor, amount: Double) -> ArtColor {
        func channel(_ shift: UInt32) -> UInt32 {
            let a = Double((rgb >> shift) & 0xFF), b = Double((other.rgb >> shift) & 0xFF)
            return UInt32((a * (1 - amount) + b * amount).rounded()) << shift
        }
        return ArtColor(channel(16) | channel(8) | channel(0), alpha: alpha)
    }
}

/// 사무실 공통 색 (설계서 §9.2 주간 팔레트, 미리보기와 같은 값). 밤 색은 `NightPalette`가 이 값에서 만듭니다 (M6(6)).
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
    /// 점선 간격 (0이면 실선). 속삭임 풍선의 점선 테두리에 씁니다.
    public var dash: Double

    public init(_ geometry: Geometry, fill: Paint? = nil, stroke: Paint? = nil, lineWidth: Double = 1.8, opacity: Double = 1, dash: Double = 0) {
        self.geometry = geometry
        self.fill = fill
        self.stroke = stroke
        self.lineWidth = lineWidth
        self.opacity = opacity
        self.dash = dash
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
        if scale != 1 {
            copy.lineWidth *= scale
            copy.dash *= scale
        }
        return copy
    }
}

extension ArtShape {
    /// 조명에 맞춘 색으로 (낮이면 그대로)
    public func lit(_ lighting: Lighting) -> ArtShape {
        guard lighting == .night else { return self }
        var copy = self
        copy.fill = fill.map(NightPalette.paint)
        copy.stroke = stroke.map(NightPalette.paint)
        return copy
    }
}

extension ArtLayer {
    public func lit(_ lighting: Lighting) -> ArtLayer {
        guard lighting == .night else { return self }
        return ArtLayer(name, depth: depth, shapes.lit(lighting))
    }
}

extension Array where Element == ArtShape {
    public func lit(_ lighting: Lighting) -> [ArtShape] {
        lighting == .night ? map { $0.lit(lighting) } : self
    }

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
