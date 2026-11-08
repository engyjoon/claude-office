import Foundation
import OfficeCore

/// 표시 배율에 따른 정보 단계 (설계서 §10.1). 글자가 뭉개지지 않게 작을수록 덜 보여줍니다.
public enum OverlayTier: Int, Hashable, Sendable, Comparable {
    /// 0.5 미만: 캐릭터, 표정, 머리 위 아이콘만. 말풍선은 외침 풍선만 (최대 10자)
    case tiny
    /// 0.5 ~ 0.8: 말풍선 최대 18자, 상태 칩 숨김
    case compact
    /// 0.8 이상: 말풍선 최대 32자, 상태 칩 표시
    case full

    public init(scale: Double) {
        self = scale < 0.5 ? .tiny : scale < 0.8 ? .compact : .full
    }

    public var maxBubbleCharacters: Int {
        switch self {
        case .tiny: 10
        case .compact: 18
        case .full: 32
        }
    }

    public var showsPills: Bool { self == .full }

    public func shows(_ kind: BubbleKind) -> Bool { self != .tiny || kind == .shout }

    public static func < (lhs: OverlayTier, rhs: OverlayTier) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// 머리 위 그림을 그릴 때의 화면 상황
public struct OverlayOptions: Hashable, Sendable {
    public var privacy: PrivacyLevel
    /// 실제 표시 배율 (사무실 1pt가 화면에서 차지하는 크기)
    public var displayScale: Double
    /// 마우스를 올린 직원. 이 직원의 말풍선은 줄이지 않고 전체를 보여줍니다.
    public var hovered: AgentID?
    /// 화면에 보이는 영역 (지도 좌표). nil이면 사무실 전체입니다. 말풍선이 이 밖으로 나가지 않게 합니다.
    public var bounds: MapRect?

    public init(privacy: PrivacyLevel = .detailed, displayScale: Double = 1, hovered: AgentID? = nil, bounds: MapRect? = nil) {
        self.privacy = privacy
        self.displayScale = displayScale
        self.hovered = hovered
        self.bounds = bounds
    }

    public var tier: OverlayTier { OverlayTier(scale: displayScale) }
}

/// 사무실 위에 겹쳐 그리는 그림 한 덩어리 (말풍선, 상태 칩, 머리 위 아이콘, 효과).
/// 도형은 `origin` 기준 좌표이고, 렌더러는 `origin`으로 옮긴 뒤 `scale`과 `opacity`를 적용합니다.
/// 도형이 그대로이고 위치·크기·투명도만 바뀌는 애니메이션은 렌더러가 노드를 다시 만들지 않아도 됩니다.
public struct OverlayItem: Hashable, Sendable, Identifiable {
    public enum Kind: String, Hashable, Sendable {
        case bubble, pill, emote, effect
    }

    public var id: String
    public var kind: Kind
    public var agent: AgentID?
    public var origin: MapPoint
    public var scale: Double = 1
    public var opacity: Double = 1
    public var shapes: [ArtShape]
    /// 말풍선·상태 칩이 차지하는 영역 (지도 좌표, 애니메이션 전 크기)
    public var frame: MapRect?
    /// 화면에 보이는 글자 (줄인 결과)
    public var text: String?
}

/// 머리 위 그림의 배치 (설계서 §7.2). 판단은 모두 여기서 하고 렌더러(SpriteKit, SVG)는 그리기만 합니다.
///
/// - 캐릭터마다 말풍선 1개, 상태 칩 1개, 아이콘 1개
/// - 말풍선 길이는 표시 단계에 따라 32·18·10자로 줄이고, 마우스를 올린 직원은 전체를 보여줍니다
/// - 겹치면 옆으로 비켜 보고, 그래도 겹치면 위로 쌓습니다. 화면 가장자리에서는 안쪽으로 밀고 꼬리가 주인을 가리킵니다
/// - 표시 수준이 "비공개"면 말풍선과 상태 칩 없이 아이콘과 표정만, "요약"이면 상태 칩을 툴 종류로 보여줍니다
public enum Overlay {
    /// 발 위치에서 머리 위 기준점까지 (머리 꼭대기 -85 바로 위)
    public static let headTop = -90.0
    static let gap = 3.0
    static let pillHeight = 17.0
    static let maxPillCharacters = 28

    public static func items(for stage: Stage, options: OverlayOptions = .init()) -> [OverlayItem] {
        let bounds = options.bounds ?? MapRect(0, 0, OfficeLayout.width, stage.layout.height)
        let area = bounds.insetBy(4)
        let tier = options.tier
        let time = stage.time
        var placed: [MapRect] = []
        var items: [OverlayItem] = []
        var pillTops: [AgentID: Double] = [:]
        // 앞(화면 아래쪽)에 선 직원부터 자리를 잡습니다
        let actors = stage.sortedActors.reversed()

        // 1) 상태 칩: 머리 바로 위
        if tier.showsPills, options.privacy != .hidden {
            for actor in actors {
                guard let pill = actor.pill else { continue }
                let label = options.privacy == .summary ? pill.category.summaryLabel : pill.text
                let text = truncate(label, maxPillCharacters)
                let width = TextMetrics.width(text, size: 9.5) + 26
                let anchor = actor.position + MapPoint(0, headTop)
                var frame = MapRect(anchor.x - width / 2, anchor.y - pillHeight, width, pillHeight)
                frame = place(frame, avoiding: placed, in: area)
                placed.append(frame)
                pillTops[actor.id] = frame.y
                let origin = MapPoint(frame.x, frame.y)
                items.append(OverlayItem(
                    id: "pill:\(actor.id.raw)", kind: .pill, agent: actor.id, origin: origin,
                    shapes: OverlayArt.pill(text: text, width: width, category: pill.category), frame: frame, text: text))
            }
        }

        // 2) 말풍선: 중요한 것(외침)부터, 같은 종류면 앞에 선 직원부터
        if options.privacy != .hidden {
            let speakers = actors
                .filter { $0.bubble.map { tier.shows($0.kind) } ?? false }
                .sorted { ($0.bubble!.kind.priority, $0.position.y) > ($1.bubble!.kind.priority, $1.position.y) }
            for actor in speakers {
                let bubble = actor.bubble!
                let limit = actor.id == options.hovered ? 60 : tier.maxBubbleCharacters
                let text = truncate(bubble.text, limit)
                let style = OverlayArt.BubbleStyle(bubble.kind)
                let width = TextMetrics.width(text, size: style.fontSize, bold: style.bold) + style.padX * 2
                let tip = MapPoint(actor.position.x, (pillTops[actor.id] ?? actor.position.y + headTop) - 1)
                var frame = MapRect(tip.x - width / 2, tip.y - 9 - style.height, width, style.height)
                frame = place(frame, avoiding: placed, in: area)
                placed.append(frame)
                // 톡 튀어나오기 (0.18초)
                let t = min(max((time - actor.bubbleShownAt) / 0.18, 0), 1)
                let scale = 0.6 + 0.4 * (1 - pow(1 - t, 3))
                let local = MapRect(frame.x - tip.x, frame.y - tip.y, frame.width, frame.height)
                items.append(OverlayItem(
                    id: "bubble:\(actor.id.raw)", kind: .bubble, agent: actor.id, origin: tip, scale: scale, opacity: 0.4 + 0.6 * t,
                    shapes: OverlayArt.bubble(bubble.kind, text: text, frame: local), frame: frame, text: text))
            }
        }

        // 3) 머리 위 아이콘: 머리 옆에서 통통
        for actor in actors {
            guard let emote = actor.emote else { continue }
            let side = emote == .exclamation ? MapPoint(-26, -82) : MapPoint(24, -84)
            let elapsed = time - actor.emoteShownAt
            let bounce = -3 * pow(sin(Double.pi * elapsed / 1.8), 2)
            let appear = min(max(elapsed / 0.2, 0), 1)
            items.append(OverlayItem(
                id: "emote:\(actor.id.raw)", kind: .emote, agent: actor.id,
                origin: actor.position + side + MapPoint(0, bounce), scale: 0.4 + 0.6 * appear, opacity: appear,
                shapes: OverlayArt.emote(emote)))
        }

        // 4) 효과
        for effect in stage.effects {
            let progress = effect.progress(at: time)
            switch effect.kind {
            case .paperPlane(let target):
                guard let actor = stage.actors[target] else { continue }
                let to = actor.position + MapPoint(10, -66)
                let from = to + MapPoint(170, -200)
                let control = MapPoint((from.x + to.x) / 2 + 40, min(from.y, to.y) - 30)
                let t = 1 - pow(1 - progress, 2)
                let point = quad(from, control, to, t)
                let ahead = quad(from, control, to, min(t + 0.02, 1)) - quad(from, control, to, max(t - 0.02, 0))
                let angle = atan2(ahead.y, ahead.x)
                items.append(OverlayItem(
                    id: "fx:\(effect.id)", kind: .effect, origin: point, opacity: progress > 0.85 ? (1 - progress) / 0.15 : 1,
                    shapes: OverlayArt.paperPlane(angle: angle)))
            case .sparkle(let at):
                items.append(OverlayItem(
                    id: "fx:\(effect.id)", kind: .effect, origin: at, scale: 0.5 + 0.7 * sin(progress * Double.pi / 2),
                    opacity: progress < 0.6 ? 1 : (1 - progress) / 0.4, shapes: OverlayArt.sparkleBurst))
            }
        }
        return items
    }

    /// 글자 수가 넘치면 `…`로 줄입니다
    public static func truncate(_ text: String, _ limit: Int) -> String {
        guard text.count > limit, limit > 1 else { return text }
        return String(text.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// 겹치지 않는 자리를 찾습니다: 화면 안으로 밀고 → 옆으로 비켜 보고 → 위로 쌓습니다.
    static func place(_ rect: MapRect, avoiding placed: [MapRect], in area: MapRect) -> MapRect {
        var frame = clamp(rect, in: area)
        func hits(_ r: MapRect) -> [MapRect] { placed.filter { $0.intersects(r, gap: gap) } }
        let blockers = hits(frame)
        guard !blockers.isEmpty else { return frame }

        // 옆으로 비키기 (말풍선 폭의 절반까지만, 주인에게서 너무 멀어지지 않게)
        let limit = frame.width / 2 + 12
        var shifts: [Double] = []
        for blocker in blockers {
            shifts.append(blocker.maxX + gap - frame.x)
            shifts.append(blocker.x - gap - frame.maxX)
        }
        for shift in shifts.sorted(by: { abs($0) < abs($1) }) where abs(shift) <= limit {
            var moved = frame
            moved.x += shift
            if moved.x >= area.x, moved.maxX <= area.maxX, hits(moved).isEmpty { return moved }
        }

        // 위로 쌓기
        for _ in 0..<8 {
            let above = hits(frame)
            guard let top = above.map(\.y).min() else { return frame }
            frame.y = top - gap - frame.height
            if frame.y < area.y {
                frame.y = area.y  // 화면 위 끝: 겹치더라도 화면 안에 둡니다
                return frame
            }
        }
        return frame
    }

    static func clamp(_ rect: MapRect, in area: MapRect) -> MapRect {
        var frame = rect
        if frame.width <= area.width {
            frame.x = min(max(frame.x, area.x), area.maxX - frame.width)
        }
        frame.y = max(frame.y, area.y)
        return frame
    }

    static func quad(_ a: MapPoint, _ c: MapPoint, _ b: MapPoint, _ t: Double) -> MapPoint {
        let u = 1 - t
        return a * (u * u) + c * (2 * u * t) + b * (t * t)
    }
}

extension MapRect {
    /// `gap`만큼 띄운 상태에서 겹치는지
    func intersects(_ other: MapRect, gap: Double = 0) -> Bool {
        x < other.maxX + gap && other.x < maxX + gap && y < other.maxY + gap && other.y < maxY + gap
    }
}

/// 글자 폭 어림 (Apple SD Gothic Neo 실측 비율). 말풍선 크기를 렌더러와 무관하게 정하려고 씁니다.
public enum TextMetrics {
    public static func width(_ text: String, size: Double, bold: Bool = false) -> Double {
        var em = 0.0
        for scalar in text.unicodeScalars {
            em += advance(scalar)
        }
        return em * size * (bold ? 1.05 : 1)
    }

    static func advance(_ scalar: Unicode.Scalar) -> Double {
        switch scalar.value {
        case 0xAC00...0xD7A3, 0x1100...0x11FF, 0x3130...0x318F, 0x3000...0x30FF, 0x4E00...0x9FFF, 0xFF00...0xFFEF, 0x2026: 0.87
        case 0x20, 0x21, 0x27, 0x2C, 0x2E, 0x3A, 0x3B, 0x7C, 0x69, 0x6A, 0x6C: 0.26
        case 0xB7: 0.31
        case 0x28, 0x29, 0x2F, 0x5B, 0x5D, 0x5F, 0x7B, 0x7D, 0x60, 0x66, 0x74, 0x72: 0.35
        case 0x2D, 0x22: 0.44
        case 0x6D, 0x77, 0x4D, 0x57: 0.82
        case 0x41...0x5A: 0.63
        case 0x30...0x39: 0.63
        case 0x61...0x7A: 0.52
        case 0x21...0x7E: 0.55
        default: 0.87
        }
    }
}

/// 말풍선 5종·상태 칩·아이콘·효과 그림 데이터 (미리보기 docs/preview의 bubble/pill/emote를 옮긴 것)
public enum OverlayArt {
    public static let thoughtFill = ArtColor(0xF4F0FD)

    struct BubbleStyle {
        var fontSize: Double
        var bold: Bool
        var padX: Double
        var height: Double
        var radius: Double

        init(_ kind: BubbleKind) {
            switch kind {
            case .speech: self.init(fontSize: 12, bold: false, padX: 11, height: 27, radius: 11)
            case .thought: self.init(fontSize: 12, bold: false, padX: 11, height: 27, radius: 13.5)
            case .shout: self.init(fontSize: 12.5, bold: true, padX: 13, height: 27, radius: 9)
            case .whisper: self.init(fontSize: 10.5, bold: false, padX: 8, height: 21, radius: 10)
            }
        }

        init(fontSize: Double, bold: Bool, padX: Double, height: Double, radius: Double) {
            self.fontSize = fontSize
            self.bold = bold
            self.padX = padX
            self.height = height
            self.radius = radius
        }
    }

    /// 말풍선. `frame`은 꼬리 끝(원점) 기준 상자입니다.
    public static func bubble(_ kind: BubbleKind, text: String, frame f: MapRect) -> [ArtShape] {
        let style = BubbleStyle(kind)
        let tip = MapPoint(0, 0)
        let label = ArtShape.text(
            text, f.x + style.padX, f.y + f.height / 2, size: style.fontSize, bold: style.bold,
            color: .swatch(.ink), anchor: .start, baseline: .central)
        switch kind {
        case .speech:
            return [ArtShape(.path(tailRect(f, radius: style.radius, tip: tip)), fill: .swatch(.white), stroke: .swatch(.ink)), label]
        case .whisper:
            var whisperLabel = label
            whisperLabel.opacity = 0.8
            return [
                ArtShape(.path(tailRect(f, radius: style.radius, tip: tip)), fill: .swatch(.white), stroke: .swatch(.ink), lineWidth: 1.3, dash: 3),
                whisperLabel,
            ]
        case .thought:
            let baseX = min(max(tip.x, f.x + f.height / 2), f.maxX - f.height / 2)
            let base = MapPoint(baseX, f.maxY)
            let near = tip + (base - tip) * 0.2
            let far = tip + (base - tip) * 0.55
            return [
                ArtShape(.rect(f, radius: f.height / 2), fill: .color(thoughtFill), stroke: .swatch(.ink)),
                ArtShape(.circle(center: far, radius: 3.4), fill: .color(thoughtFill), stroke: .swatch(.ink)),
                ArtShape(.circle(center: near, radius: 2), fill: .color(thoughtFill), stroke: .swatch(.ink)),
                label,
            ]
        case .shout:
            let burst = "M\(n(f.x - 5)),\(n(f.y - 3)) l-5,-4 M\(n(f.maxX + 5)),\(n(f.y - 3)) l5,-4 M\(n(f.maxX + 6)),\(n(f.y + 8)) l7,0"
            return [
                ArtShape(.path(tailRect(f, radius: style.radius, tip: tip)), fill: .swatch(.butter), stroke: .swatch(.ink), lineWidth: 2.4),
                .line(burst, width: 1.8),
                .circle(f.x + 2, f.y + 1, 8, fill: .swatch(.alert)),
                .text("!", f.x + 2, f.y + 1, size: 12, bold: true, color: .swatch(.white), baseline: .central),
                label,
            ]
        }
    }

    /// 꼬리 달린 둥근 사각형. 꼬리 뿌리는 상자 아래쪽 안에 두고, 끝은 주인의 머리 위를 가리킵니다.
    static func tailRect(_ f: MapRect, radius r: Double, tip: MapPoint) -> [PathCommand] {
        let base = min(max(tip.x, f.x + r + 6), f.maxX - r - 6)
        return [
            .move(MapPoint(f.x + r, f.y)),
            .line(MapPoint(f.maxX - r, f.y)), .quad(control: MapPoint(f.maxX, f.y), to: MapPoint(f.maxX, f.y + r)),
            .line(MapPoint(f.maxX, f.maxY - r)), .quad(control: MapPoint(f.maxX, f.maxY), to: MapPoint(f.maxX - r, f.maxY)),
            .line(MapPoint(base + 6, f.maxY)), .line(tip), .line(MapPoint(base - 6, f.maxY)),
            .line(MapPoint(f.x + r, f.maxY)), .quad(control: MapPoint(f.x, f.maxY), to: MapPoint(f.x, f.maxY - r)),
            .line(MapPoint(f.x, f.y + r)), .quad(control: MapPoint(f.x, f.y), to: MapPoint(f.x + r, f.y)),
            .close,
        ]
    }

    /// 상태 칩. 원점은 칩의 왼쪽 위입니다.
    public static func pill(text: String, width: Double, category: ToolCategory) -> [ArtShape] {
        [
            ArtShape(.rect(MapRect(0, 0, width, 17), radius: 8.5), fill: .swatch(.ink)),
            .circle(10, 8.5, 3, fill: .color(categoryColor(category)), outline: false),
            .text(text, 17, 8.5, size: 9.5, color: .swatch(.white), anchor: .start, baseline: .central),
        ]
    }

    /// 툴 종류 색 (미리보기의 CAT)
    public static func categoryColor(_ category: ToolCategory) -> ArtColor {
        switch category {
        case .write: ArtColor(0x7FD6B6)
        case .read: ArtColor(0xB9A8F2)
        case .shell: ArtColor(0x8CC8EE)
        case .web: ArtColor(0xF2C88B)
        case .plan: ArtColor(0xF7DE8B)
        case .delegate: ArtColor(0xF6B9A0)
        case .mcp: ArtColor(0xF4A3B4)
        case .report: ArtColor(0x9FD8C7)
        case .other: ArtColor(0xCCCCCC)
        }
    }

    /// 머리 위 아이콘 (원점: 아이콘 가운데)
    public static func emote(_ emote: Emote) -> [ArtShape] {
        switch emote {
        case .exclamation:
            return [.circle(0, 0, 8.5, fill: .swatch(.alert)), .text("!", 0, 0, size: 13, bold: true, color: .swatch(.white), baseline: .central)]
        case .question:
            return [.circle(0, 0, 8.5, fill: .swatch(.lavender)), .text("?", 0, 0, size: 13, bold: true, color: .swatch(.ink), baseline: .central)]
        case .bulb:
            return [
                .line("M-12,-4 l-4,-2 M12,-4 l4,-2 M0,-15 l0,-4 M-9,-12 l-3,-3 M9,-12 l3,-3", width: 1.6),
                .circle(0, -3, 8, fill: .swatch(.butter)),
                .rect(-4, 5, 8, 5, r: 1.5, fill: .swatch(.metal)),
            ]
        case .sweat:
            return [.path("M0,-8 q-6,8 0,11 q6,-3 0,-11 Z", fill: .swatch(.drop))]
        case .sparkle:
            return [
                ArtShape(.path(CharacterArt.star4(MapPoint(0, 0), 8)), fill: .swatch(.butter), stroke: .swatch(.ink), lineWidth: 1.4),
                ArtShape(.path(CharacterArt.star4(MapPoint(11, -8), 4)), fill: .swatch(.butter), stroke: .swatch(.ink), lineWidth: 1.1),
            ]
        case .zzz:
            return [
                .text("z", -2, 4, size: 13, bold: true, color: .swatch(.ink)),
                .text("Z", 8, -6, size: 16, bold: true, color: .swatch(.ink)),
            ]
        case .note:
            return [
                .ellipse(-2.5, 4, 4.2, 3.2, fill: .swatch(.ink)),
                .line("M1.4,3.5 L1.4,-11 Q6,-9 7.5,-4", width: 2),
            ]
        }
    }

    /// 종이비행기 (원점: 비행기 가운데, `angle` 방향으로 날아감)
    public static func paperPlane(angle: Double) -> [ArtShape] {
        let c = cos(angle), s = sin(angle)
        let rotate: (MapPoint) -> MapPoint = { MapPoint($0.x * c - $0.y * s, $0.x * s + $0.y * c) }
        let wing = VectorPath.transformed(VectorPath.parse("M10,0 L-8,-7 L-3,0 L-8,6 Z"), rotate)
        let crease = VectorPath.transformed(VectorPath.parse("M10,0 L-3,0"), rotate)
        return [
            ArtShape(.path(wing), fill: .swatch(.white), stroke: .swatch(.ink), lineWidth: 1.4),
            ArtShape(.path(crease), stroke: .swatch(.ink), lineWidth: 1.1),
        ]
    }

    /// 하이파이브 반짝임
    public static let sparkleBurst: [ArtShape] = [
        ArtShape(.path(CharacterArt.star4(MapPoint(0, 0), 9)), fill: .swatch(.butter), stroke: .swatch(.ink), lineWidth: 1.4),
        ArtShape(.path(CharacterArt.star4(MapPoint(15, -9), 4.5)), fill: .swatch(.butter), stroke: .swatch(.ink), lineWidth: 1.1),
        ArtShape(.path(CharacterArt.star4(MapPoint(-14, -6), 3.6)), fill: .swatch(.white), stroke: .swatch(.ink), lineWidth: 1),
    ]

    static func n(_ value: Double) -> String { VectorPath.format(value) }
}
