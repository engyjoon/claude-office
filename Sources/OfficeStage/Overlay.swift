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
    /// 사무실 조명 (M6(6)). 밤에는 잉크색 상태 칩이 어두운 바닥에 묻히지 않게 옅은 테두리를 답니다.
    public var lighting: Lighting
    /// 시스템 "대비 증가" (M6(7)): 상태 칩·배지 테두리를 진하게 합니다.
    public var highContrast: Bool
    /// 고른 직원 (M6(15)). 머리 위(상태 칩이 있으면 칩 위)에 팀 색 ▼를 띄웁니다.
    public var selected: AgentID?

    public init(
        privacy: PrivacyLevel = .detailed, displayScale: Double = 1, hovered: AgentID? = nil, bounds: MapRect? = nil, lighting: Lighting = .day,
        highContrast: Bool = false, selected: AgentID? = nil
    ) {
        self.privacy = privacy
        self.displayScale = displayScale
        self.hovered = hovered
        self.bounds = bounds
        self.lighting = lighting
        self.highContrast = highContrast
        self.selected = selected
    }

    public var tier: OverlayTier { OverlayTier(scale: displayScale) }
}

/// 사무실 위에 겹쳐 그리는 그림 한 덩어리 (말풍선, 상태 칩, 머리 위 아이콘, 효과).
/// 도형은 `origin` 기준 좌표이고, 렌더러는 `origin`으로 옮긴 뒤 `scale`과 `opacity`를 적용합니다.
/// 도형이 그대로이고 위치·크기·투명도만 바뀌는 애니메이션은 렌더러가 노드를 다시 만들지 않아도 됩니다.
public struct OverlayItem: Hashable, Sendable, Identifiable {
    public enum Kind: String, Hashable, Sendable {
        case bubble, pill, emote, effect
        /// 답변 필요·확인 안 함 배지 (M6(4))
        case badge
        /// 고른 직원 머리 위 ▼ (M6(15))
        case selection
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
    /// 발 위치에서 배지 가운데까지 (머리 왼쪽 위, M6(4))
    public static let badgeOffset = MapPoint(-25, -86)
    /// 고른 직원 ▼ 크기 (M6(15)). 끝이 머리(칩) 위 2pt를 가리킵니다.
    public static let markerSize = MapPoint(18, 11)
    static let markerGap = 2.0
    static let gap = 3.0
    static let pillHeight = 17.0
    static let maxPillCharacters = 28
    /// 같은 공용 구역(화이트보드·탕비 코너 …)에서 이만큼 넘게 칩이 뜨면 하나로 묶습니다 ("화이트보드 · 3명 계획 정리 중")
    public static let pillGroupThreshold = 3

    public static func items(for stage: Stage, options: OverlayOptions = .init()) -> [OverlayItem] {
        let bounds = options.bounds ?? MapRect(0, 0, stage.layout.width, stage.layout.height)
        let area = bounds.insetBy(4)
        let tier = options.tier
        let time = stage.time
        var placed: [MapRect] = []
        var items: [OverlayItem] = []
        var pillTops: [AgentID: Double] = [:]
        // 앞(화면 아래쪽)에 선 직원부터 자리를 잡습니다
        let actors = stage.sortedActors.reversed()

        // 1) 상태 칩: 머리 바로 위. 공용 구역에 여럿이 모이면 칩이 위로 쌓여 화면 밖으로 밀리지 않도록 하나로 묶습니다.
        if tier.showsPills, options.privacy != .hidden {
            var grouped = Set<AgentID>()
            for group in pillGroups(actors) {
                let text = group.text
                let width = TextMetrics.width(text, size: 9.5) + 26
                let anchor = MapPoint(group.centerX, group.top + headTop)
                var frame = MapRect(anchor.x - width / 2, anchor.y - pillHeight, width, pillHeight)
                frame = place(frame, avoiding: placed, in: area)
                placed.append(frame)
                for member in group.members {
                    grouped.insert(member.id)
                    pillTops[member.id] = frame.y
                }
                items.append(OverlayItem(
                    id: "pill:zone:\(group.zone.rawValue)", kind: .pill, agent: nil, origin: MapPoint(frame.x, frame.y),
                    shapes: OverlayArt.pill(text: text, width: width, category: group.category, lighting: options.lighting, contrast: options.highContrast), frame: frame, text: text))
            }
            for actor in actors where !grouped.contains(actor.id) {
                guard let pill = actor.pill else { continue }
                let label = options.privacy == .summary ? pill.summary : pill.text
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
                    shapes: OverlayArt.pill(text: text, width: width, category: pill.category, lighting: options.lighting, contrast: options.highContrast), frame: frame, text: text))
            }
        }

        // 1.5) 고른 직원 ▼ (M6(15)): 머리 바로 위, 상태 칩이 있으면 칩 위. 가구보다 위 층이라 소파·안마 의자·책상에서도 가려지지 않습니다.
        //      머리 왼쪽 위 배지("?"·✉·"!")와 오른쪽 위 Zz·♪는 가운데를 비워 두므로 겹치지 않습니다. 말풍선은 ▼ 위로 올라갑니다.
        //      움직이지 않으므로 그리기 빈도를 올리지 않습니다.
        var markerTops: [AgentID: Double] = [:]
        if let selected = options.selected, let actor = stage.actors[selected] {
            let base = pillTops[selected] ?? actor.position.y + headTop
            var frame = MapRect(actor.position.x - markerSize.x / 2, base - markerGap - markerSize.y, markerSize.x, markerSize.y)
            frame = clamp(frame, in: area)
            placed.append(frame)
            markerTops[selected] = frame.y
            let colorIndex = stage.teams[actor.agent.teamID]?.colorIndex ?? 0
            let team = Swatch.teamColors[colorIndex % Swatch.teamColors.count].color
            items.append(OverlayItem(
                id: "selection:\(selected.raw)", kind: .selection, agent: selected, origin: MapPoint(frame.x + frame.width / 2, frame.maxY),
                shapes: OverlayArt.selectionMarker(team: team, lighting: options.lighting, contrast: options.highContrast), frame: frame))
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
                var tip = MapPoint(actor.position.x, (markerTops[actor.id] ?? pillTops[actor.id] ?? actor.position.y + headTop) - 1)
                var frame = MapRect(tip.x - width / 2, tip.y - 9 - style.height, width, style.height)
                frame = place(frame, avoiding: placed, in: area)
                // 화면 위 끝에 밀려 상자가 머리까지 내려오면 꼬리가 아래로 머리를 가리킬 수 없습니다
                // (M6(9): 미니에서 문으로 나가거나 메인 옆에서 보고할 때 꼬리가 상자를 뚫고 위로 솟았음). 머리 옆에 둡니다.
                if frame.maxY > tip.y - minTail {
                    let side = besideHead(
                        width: width, height: style.height, headX: actor.position.x, top: tip.y + sideDrop, avoiding: placed, in: area)
                    frame = side.frame
                    tip = MapPoint(actor.position.x + sideTipOffset * side.direction, actor.position.y + headTop + sideTipDrop)
                }
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
            var side = emote == .exclamation ? MapPoint(-26, -82) : MapPoint(24, -84)
            // 상태 칩이 머리 위에 떠 있으면 칩과 겹치지 않게 머리 옆으로 조금 내립니다 (⏳ + "Bash · swift build")
            if pillTops[actor.id] != nil { side.y = -68; side.x = emote == .exclamation ? -28 : 28 }
            let elapsed = time - actor.emoteShownAt
            let bounce = -3 * pow(sin(Double.pi * elapsed / 1.8), 2)
            let appear = min(max(elapsed / 0.2, 0), 1)
            items.append(OverlayItem(
                id: "emote:\(actor.id.raw)", kind: .emote, agent: actor.id,
                origin: actor.position + side + MapPoint(0, bounce), scale: 0.4 + 0.6 * appear, opacity: appear,
                shapes: OverlayArt.emote(emote)))
        }

        // 4) 배지 (M6(4)): 머리 왼쪽 위에 가만히. 오른쪽 위는 Zz·♪ 자리라 겹치지 않고, 계속 움직이지 않아 쉬는 장면의
        //    그리기 빈도를 올리지 않습니다 (나타날 때 0.2초만 커짐). 승인 대기 "!"(왼쪽)와는 같은 사람에게 동시에 붙지 않습니다.
        for actor in actors {
            guard let badge = actor.badge else { continue }
            var side = badgeOffset
            if pillTops[actor.id] != nil { side = MapPoint(-30, -68) }
            let appear = min(max((time - actor.badgeShownAt) / 0.2, 0), 1)
            items.append(OverlayItem(
                id: "badge:\(actor.id.raw)", kind: .badge, agent: actor.id,
                origin: actor.position + side, scale: 0.4 + 0.6 * appear, opacity: appear,
                shapes: OverlayArt.badge(badge, lighting: options.lighting, contrast: options.highContrast)))
        }

        // 5) 효과
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

    struct PillGroup {
        var zone: OfficeLayout.Zone
        var members: [StageActor]
        var category: ToolCategory
        var text: String
        var centerX: Double
        var top: Double
    }

    /// 공용 구역마다 칩이 뜬 직원을 모아, 문턱을 넘는 구역만 묶음으로 돌려줍니다
    static func pillGroups(_ actors: ReversedCollection<[StageActor]>) -> [PillGroup] {
        var byZone: [OfficeLayout.Zone: [StageActor]] = [:]
        for actor in actors where actor.pill != nil {
            guard let zone = OfficeLayout.zone(ofKey: actor.place?.key), zone != .lounge, zone != .massageChair else { continue }
            byZone[zone, default: []].append(actor)
        }
        return byZone.keys.sorted { $0.rawValue < $1.rawValue }.compactMap { zone in
            let members = byZone[zone]!
            guard members.count >= pillGroupThreshold else { return nil }
            // 가장 많은 툴 종류로 묶음 이름을 정합니다
            var counts: [ToolCategory: Int] = [:]
            for member in members { counts[member.pill!.category, default: 0] += 1 }
            let category = counts.max { ($0.value, $1.key.summaryLabel) < ($1.value, $0.key.summaryLabel) }!.key
            let xs = members.map(\.position.x)
            return PillGroup(
                zone: zone, members: members, category: category,
                text: "\(zoneLabel(zone)) · \(members.count)명 \(groupVerb(category))",
                centerX: (xs.min()! + xs.max()!) / 2, top: members.map(\.position.y).min()!)
        }
    }

    static func zoneLabel(_ zone: OfficeLayout.Zone) -> String {
        switch zone {
        case .whiteboard: "화이트보드"
        case .pantry: "탕비 코너"
        case .lounge, .massageChair: "휴게 공간"
        }
    }

    static func groupVerb(_ category: ToolCategory) -> String {
        switch category {
        case .read: "읽는 중"
        case .write: "편집 중"
        case .shell: "명령 실행 중"
        case .web: "검색 중"
        case .plan: "계획 중"
        case .delegate, .report, .mcp, .other: "일하는 중"
        }
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

    /// 아래 꼬리의 가장 짧은 길이. 상자가 이보다 머리에 붙으면 머리 옆에 둡니다.
    static let minTail = 5.0
    /// 머리 옆 말풍선: 상자 안쪽 끝은 머리 가운데에서 이만큼 옆, 위 끝은 머리 위 기준점에서 이만큼 아래
    static let sideGap = 30.0
    static let sideDrop = 6.0
    /// 머리 옆 말풍선의 꼬리 끝: 머리 가운데에서 옆으로, 머리 위 기준점에서 아래로 (머리 윗부분 옆)
    static let sideTipOffset = 20.0
    static let sideTipDrop = 25.0

    /// 머리 옆 자리 (M6(9)). 오른쪽부터, 다른 말풍선·칩과 겹치면 바깥으로 비켜 보고, 안 되면 왼쪽.
    /// 둘 다 겹치면 화면 안에 들어가는 쪽(오른쪽 먼저)에 겹친 채 둡니다. `direction`은 오른쪽 1, 왼쪽 −1.
    static func besideHead(
        width: Double, height: Double, headX: Double, top: Double, avoiding placed: [MapRect], in area: MapRect
    ) -> (frame: MapRect, direction: Double) {
        let y = max(top, area.y)
        func hits(_ r: MapRect) -> [MapRect] { placed.filter { $0.intersects(r, gap: gap) } }
        func fits(_ r: MapRect) -> Bool { r.x >= area.x && r.maxX <= area.maxX }
        let right = MapRect(headX + sideGap, y, width, height)
        let left = MapRect(headX - sideGap - width, y, width, height)
        for (start, direction) in [(right, 1.0), (left, -1.0)] {
            var frame = start
            for _ in 0..<4 where fits(frame) {
                let blockers = hits(frame)
                if blockers.isEmpty { return (frame, direction) }
                frame.x = direction > 0 ? blockers.map(\.maxX).max()! + gap : blockers.map(\.x).min()! - gap - width
            }
        }
        if fits(right) { return (right, 1) }
        if fits(left) { return (left, -1) }
        let direction: Double = headX < area.x + area.width / 2 ? 1 : -1
        return (clamp(direction > 0 ? right : left, in: area), direction)
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
            // 꼬리 끝이 상자 옆이면(머리 옆 말풍선, M6(9)) 점도 옆으로 이어 갑니다
            let base: MapPoint =
                switch tailSide(f, tip: tip) {
                case .right: MapPoint(f.maxX, f.y + f.height / 2)
                case .left: MapPoint(f.x, f.y + f.height / 2)
                case .bottom, .none: MapPoint(min(max(tip.x, f.x + f.height / 2), f.maxX - f.height / 2), f.maxY)
                }
            let near = tip + (base - tip) * 0.2
            let far = tip + (base - tip) * 0.55
            return [
                ArtShape(.rect(f, radius: f.height / 2), fill: .color(thoughtFill), stroke: .swatch(.ink)),
                ArtShape(.circle(center: far, radius: 3.4), fill: .color(thoughtFill), stroke: .swatch(.ink)),
                ArtShape(.circle(center: near, radius: 2), fill: .color(thoughtFill), stroke: .swatch(.ink)),
                label,
            ]
        case .shout:
            // 터지는 선: 위 양쪽 모서리와 좌우 가운데 (왼쪽 가운데는 M5(9b) 화면 확인: "!" 배지를 없애 오른쪽과 짝이 맞게)
            let burst = "M\(n(f.x - 5)),\(n(f.y - 3)) l-5,-4 M\(n(f.maxX + 5)),\(n(f.y - 3)) l5,-4 "
                + "M\(n(f.maxX + 6)),\(n(f.y + 8)) l7,0 M\(n(f.x - 6)),\(n(f.y + 8)) l-7,0"
            return [
                ArtShape(.path(tailRect(f, radius: style.radius, tip: tip)), fill: .swatch(.butter), stroke: .swatch(.ink), lineWidth: 2.4),
                .line(burst, width: 1.8),
                // 왼쪽 위 "!" 원은 없앰 (M5(9) 화면 확인: 머리 위 "!" 아이콘과 겹쳐 두 번 보임)
                label,
            ]
        }
    }

    enum TailSide { case bottom, right, left, none }

    /// 꼬리를 낼 변. 꼬리 끝이 상자 아래면 아래, 상자 옆이면 그 옆, 상자 안이면 꼬리 없음.
    /// 꼬리가 상자를 가로질러 그려지는 일이 없게 합니다 (M6(9)).
    static func tailSide(_ f: MapRect, tip: MapPoint) -> TailSide {
        if tip.y >= f.maxY { return .bottom }
        if tip.x >= f.maxX { return .right }
        if tip.x <= f.x { return .left }
        return .none
    }

    /// 꼬리 달린 둥근 사각형. 꼬리 뿌리는 상자 아래쪽 안에 두고, 끝은 주인의 머리 위를 가리킵니다.
    /// 머리 옆 말풍선(M6(9))이면 꼬리 뿌리를 머리 쪽 옆변 가운데에 둡니다.
    static func tailRect(_ f: MapRect, radius r: Double, tip: MapPoint) -> [PathCommand] {
        let side = tailSide(f, tip: tip)
        // 옆 꼬리: 뿌리 폭 ±5를 옆변 가운데에 두고, 그 옆 모서리는 뿌리에 닿지 않을 만큼만 둥글게 합니다
        let cy = f.y + f.height / 2
        let upper = min(f.y + r, cy - 5), lower = max(f.maxY - r, cy + 5)
        var right: [PathCommand] = [
            .quad(control: MapPoint(f.maxX, f.y), to: MapPoint(f.maxX, f.y + r)),
            .line(MapPoint(f.maxX, f.maxY - r)), .quad(control: MapPoint(f.maxX, f.maxY), to: MapPoint(f.maxX - r, f.maxY)),
        ]
        var left: [PathCommand] = [
            .quad(control: MapPoint(f.x, f.maxY), to: MapPoint(f.x, f.maxY - r)),
            .line(MapPoint(f.x, f.y + r)), .quad(control: MapPoint(f.x, f.y), to: MapPoint(f.x + r, f.y)),
        ]
        if side == .right {
            right = [
                .quad(control: MapPoint(f.maxX, f.y), to: MapPoint(f.maxX, upper)),
                .line(MapPoint(f.maxX, cy - 5)), .line(tip), .line(MapPoint(f.maxX, cy + 5)),
                .line(MapPoint(f.maxX, lower)), .quad(control: MapPoint(f.maxX, f.maxY), to: MapPoint(f.maxX - r, f.maxY)),
            ]
        } else if side == .left {
            left = [
                .quad(control: MapPoint(f.x, f.maxY), to: MapPoint(f.x, lower)),
                .line(MapPoint(f.x, cy + 5)), .line(tip), .line(MapPoint(f.x, cy - 5)),
                .line(MapPoint(f.x, upper)), .quad(control: MapPoint(f.x, f.y), to: MapPoint(f.x + r, f.y)),
            ]
        }
        var bottom: [PathCommand] = []
        if side == .bottom {
            let base = min(max(tip.x, f.x + r + 6), f.maxX - r - 6)
            bottom = [.line(MapPoint(base + 6, f.maxY)), .line(tip), .line(MapPoint(base - 6, f.maxY))]
        }
        return [.move(MapPoint(f.x + r, f.y)), .line(MapPoint(f.maxX - r, f.y))] + right + bottom
            + [.line(MapPoint(f.x + r, f.maxY))] + left + [.close]
    }

    /// 상태 칩. 원점은 칩의 왼쪽 위입니다. 밤에는 흰 30% 테두리를 1pt 답니다 (M6(6)).
    /// 대비 증가(M6(7))면 밤 테두리를 흰 85% 1.5pt로, 낮에는 흰 1pt 안쪽 선을 둘러 잉크 칩이 짙은 가구·머리카락 위에서도 떨어져 보이게 합니다.
    public static func pill(text: String, width: Double, category: ToolCategory, lighting: Lighting = .day, contrast: Bool = false) -> [ArtShape] {
        let edge: ArtColor? = contrast ? (lighting == .night ? pillContrastNightEdge : ArtColor(0xFFFFFF)) : lighting == .night ? pillNightEdge : nil
        return [
            ArtShape(
                .rect(MapRect(0, 0, width, 17), radius: 8.5), fill: .swatch(.ink),
                stroke: edge.map { .color($0) }, lineWidth: contrast ? 1.5 : lighting == .night ? 1 : 1.8),
            .circle(10, 8.5, 3, fill: .color(categoryColor(category)), outline: false),
            .text(text, 17, 8.5, size: 9.5, color: .swatch(.white), anchor: .start, baseline: .central),
        ]
    }

    /// 밤 상태 칩 테두리
    public static let pillNightEdge = ArtColor(0xFFFFFF, alpha: 0.3)
    /// 대비 증가 + 밤 상태 칩 테두리 (M6(7))
    public static let pillContrastNightEdge = ArtColor(0xFFFFFF, alpha: 0.85)

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
        case .hourglass:
            // 모래시계 ⏳: 위 모래가 줄고 아래 모래가 쌓인 모습
            return [
                .circle(0, 0, 9, fill: .swatch(.white)),
                .rect(-6, -7.5, 12, 2.4, r: 1.2, fill: .swatch(.woodDark), width: 1),
                .rect(-6, 5.1, 12, 2.4, r: 1.2, fill: .swatch(.woodDark), width: 1),
                .path("M-4.2,-5 L4.2,-5 L0.8,0 L4.2,5 L-4.2,5 L-0.8,0 Z", fill: .swatch(.sky), width: 1.2),
                .path("M-2.2,-3.6 L2.2,-3.6 L0,-0.8 Z", fill: .swatch(.butter), outline: false),
                .path("M-3.4,4.6 Q0,1.4 3.4,4.6 Z", fill: .swatch(.butter), outline: false),
            ]
        }
    }

    /// 답변 필요·확인 안 함 배지 (원점: 배지 가운데, M6(4)).
    /// 답변 필요 = 파란 말풍선에 흰 "?" (승인 대기 "!"의 주황 원과 색·모양이 다름),
    /// 확인 안 함 = 흰 원 안 편지 ✉ + 파란 점 (데스크톱 앱 사이드바의 안 읽음 점과 같은 뜻).
    /// 대비 증가(M6(7))면 "?" 풍선에 테두리(낮 잉크, 밤 흰색)를 두르고 ✉ 원 테두리를 굵게 합니다.
    public static func badge(_ cue: SessionCue, lighting: Lighting = .day, contrast: Bool = false) -> [ArtShape] {
        let blue = Paint.color(ArtColor(0x5B8DEF))
        switch cue {
        case .reply:
            var shapes: [ArtShape] = []
            if contrast {
                // 풍선 모양 그대로 테두리만 먼저 굵게 그리고 그 위에 원래 풍선을 덮습니다 (꼬리 이음매에 선이 남지 않게)
                let edge: Paint = lighting == .night ? .swatch(.white) : .swatch(.ink)
                shapes += [
                    ArtShape(.path(VectorPath.parse("M4,7 L8,13.5 L-2,7 Z")), fill: edge, stroke: edge, lineWidth: 3),
                    ArtShape(.rect(MapRect(-11.5, -11, 23, 19), radius: 8), fill: edge, stroke: edge, lineWidth: 3),
                ]
            }
            return shapes + [
                // 꼬리는 머리 쪽(오른쪽 아래)을 가리킵니다 (배지가 머리 왼쪽 위에 있으므로)
                .path("M4,7 L8,13.5 L-2,7 Z", fill: blue),
                .rect(-11.5, -11, 23, 19, r: 8, fill: blue),
                .line("M-1.4,7 L3.6,7", width: 2.6, color: blue),
                .text("?", 0, -1.5, size: 14, bold: true, color: .swatch(.white), baseline: .central),
            ]
        case .unread:
            return [
                .circle(0, 0, 10.5, fill: .swatch(.white), width: contrast ? 2.6 : 1.8),
                .rect(-6, -4.5, 12, 9, r: 1.5, fill: .swatch(.sky), width: 1.4),
                .path("M-6,-3.8 L0,1 L6,-3.8", width: 1.4),
                ArtShape(.circle(center: MapPoint(8, -8), radius: 3.4), fill: .color(ArtColor(0x4A8FE0)), stroke: .swatch(.white), lineWidth: 1.3),
            ]
        }
    }

    /// 고른 직원 머리 위 ▼ (원점: 아래 끝, M6(15)). 팀 색에 잉크 테두리, 바깥에 밝은 테(밤은 따뜻한 흰색)를 둘러
    /// 낮 크림 바닥·밤 남색 바닥 어디서나 보이게 합니다. 대비 증가면 잉크 테두리를 굵게 합니다.
    /// 배지("?" 파란 풍선, ✉ 흰 원)·승인 대기 "!"(주황 원)와 모양·색이 겹치지 않습니다.
    public static func selectionMarker(team: ArtColor, lighting: Lighting = .day, contrast: Bool = false) -> [ArtShape] {
        let size = Overlay.markerSize
        let w = size.x / 2, h = size.y
        let d = "M\(n(-w)),\(n(-h)) L\(n(w)),\(n(-h)) L0,0 Z"
        let edge = Paint.color(lighting == .night ? CharacterArt.nightOutlineEdge : ArtColor(0xFFFFFF))
        return [
            .path(d, fill: edge, width: 5, stroke: edge),
            .path(d, fill: .color(team), width: contrast ? 2.4 : 1.8),
        ]
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
