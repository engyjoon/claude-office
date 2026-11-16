import Foundation
import OfficeCore

/// 사무실 꾸밈 그림 (2026-11-16 디자인 다듬기): 화분, 풍경 창의 커튼·창턱, 벽시계, 화이트보드, 출입문, 게시판, 우산꽂이, 선반.
/// 모두 뒷벽 층(깊이 −∞)이나 기존 가구 층에 얹는 도형이라 층(구운 텍스처) 수는 늘지 않습니다.
/// 바닥에 서는 것(큰 화분·우산꽂이)은 걸을 수 있는 영역(`OfficeLayout.walkTop`)보다 위, 벽 바로 앞에만 놓습니다.
extension OfficeArt {
    static let leafLight = ArtColor(0x9FD8C7)
    static let leafMid = ArtColor(0x86C9A9)
    static let leafDeep = ArtColor(0x6FB592)
    static let stemGreen = ArtColor(0x5FA77F)
    static let potLight = ArtColor(0xF3BDA4)
    static let ceramic = ArtColor(0xFBF7F0)

    // MARK: - 잎과 화분

    /// 잎 한 장: `base`에서 `angle`(도, 0 = 오른쪽, −90 = 위) 쪽으로 `length`만큼 뻗고, 가운데가 `width`만큼 통통합니다. 잎맥 한 줄.
    static func leaf(_ base: MapPoint, angle: Double, length: Double, width: Double, fill: ArtColor, line: Double = 1.4) -> [ArtShape] {
        let a = angle * Double.pi / 180
        let dir = MapPoint(cos(a), sin(a))
        let normal = MapPoint(-sin(a), cos(a))
        let tip = base + dir * length
        let mid = base + dir * (length * 0.42)
        let outline: [PathCommand] = [.move(base), .quad(control: mid + normal * width, to: tip), .quad(control: mid - normal * width, to: base), .close]
        let vein: [PathCommand] = [.move(base + dir * (length * 0.16)), .line(base + dir * (length * 0.76))]
        return [
            ArtShape(.path(outline), fill: .color(fill), stroke: .swatch(.ink), lineWidth: line),
            ArtShape(.path(vein), stroke: .color(fill.mixed(with: ArtColor(0x3A3247), amount: 0.28)), lineWidth: line * 0.6),
        ]
    }

    /// 테두리(림)가 있는 화분 (원점: 바닥 가운데)
    static func pot(width: Double, height: Double, fill: ArtColor, rim: ArtColor, line: Double = 1.6) -> [ArtShape] {
        let w = width / 2
        return [
            .path("M\(-w),\(-height) H\(w) L\(w * 0.76),0 H\(-w * 0.76) Z", fill: .color(fill), width: line),
            .rect(-w - 1.5, -height - 3.5, width + 3, 5.5, r: 2.4, fill: .color(rim), width: line),
        ]
    }

    /// 화분 (발 위치 기준). 책상 위(작게)와 창턱에 씁니다: 잎 다섯 장이 부채꼴로 퍼집니다.
    static func plant(at origin: MapPoint, scale: Double) -> [ArtShape] {
        let base = MapPoint(0, -22)
        let shapes =
            leaf(base, angle: -164, length: 21, width: 7, fill: leafLight)
            + leaf(base, angle: -16, length: 21, width: 7, fill: leafMid)
            + leaf(base, angle: -128, length: 31, width: 9, fill: leafMid)
            + leaf(base, angle: -52, length: 31, width: 9, fill: leafLight)
            + leaf(base, angle: -92, length: 37, width: 8.5, fill: leafDeep)
            + pot(width: 22, height: 19, fill: Swatch.pot.color, rim: potLight)
        return shapes.transformed(scale: scale, offset: origin)
    }

    /// 벽 앞에 세워 두는 큰 화분 (고무나무): 줄기 양옆으로 큰 잎이 어긋나게 납니다. 높이 약 70.
    static func floorPlant(at foot: MapPoint) -> [ArtShape] {
        var shapes: [ArtShape] = [
            .ellipse(0, 0, 15, 3.6, fill: .swatch(.shadow)),
            .line("M0,-22 C1,-34 -1,-44 0,-54", width: 2.2, color: .color(ArtColor(0x8C6B52))),
        ]
        let leaves: [(Double, Double, Double, Double, ArtColor)] = [
            (-29, -158, 22, 9, leafMid), (-31, -24, 22, 9, leafLight),
            (-39, -146, 24, 10, leafDeep), (-41, -36, 24, 10, leafMid),
            (-49, -128, 22, 9, leafLight), (-50, -54, 22, 9, leafDeep),
            (-53, -90, 20, 8.5, leafMid),
        ]
        for (y, angle, length, width, color) in leaves {
            shapes += leaf(MapPoint(0, y), angle: angle, length: length, width: width, fill: color, line: 1.5)
        }
        shapes += pot(width: 25, height: 21, fill: ceramic, rim: ceramic, line: 1.7)
        shapes.append(.rect(-9.6, -12, 19.2, 3.4, fill: .swatch(.lavender), outline: false))
        return shapes.transformed(offset: foot)
    }

    /// 창턱·선반에 놓는 작은 화분 셋 (원점: 놓는 면의 가운데)
    static func tinyPot(_ kind: Int, at origin: MapPoint) -> [ArtShape] {
        var shapes: [ArtShape]
        switch kind % 3 {
        case 0:
            // 다육이
            shapes = leaf(MapPoint(0, -7), angle: -150, length: 8, width: 3.4, fill: leafLight, line: 1)
                + leaf(MapPoint(0, -7), angle: -30, length: 8, width: 3.4, fill: leafLight, line: 1)
                + leaf(MapPoint(0, -7), angle: -90, length: 9.5, width: 3.6, fill: leafMid, line: 1)
                + pot(width: 10, height: 6, fill: Swatch.peach.color, rim: potLight, line: 1.1)
        case 1:
            // 선인장 + 꽃
            shapes = [
                .rect(-3, -18, 6, 12, r: 3, fill: .color(leafMid), width: 1.1),
                .rect(2.4, -14.6, 4.4, 3.6, r: 1.8, fill: .color(leafMid), width: 1.1),
                .line("M0,-16 L0,-9", width: 0.8, color: .color(leafDeep)),
                .circle(0, -18.6, 1.9, fill: .swatch(.pink), width: 0.9),
            ] + pot(width: 10, height: 6, fill: Swatch.butter.color, rim: ArtColor(0xFBE9B0), line: 1.1)
        default:
            // 새싹
            shapes = [.line("M0,-6 L0,-12", width: 1.3, color: .color(stemGreen))]
                + leaf(MapPoint(0, -12), angle: -150, length: 7, width: 3, fill: leafLight, line: 1)
                + leaf(MapPoint(0, -12), angle: -40, length: 8, width: 3.2, fill: leafMid, line: 1)
                + pot(width: 9, height: 6, fill: Swatch.lavender.color, rim: ArtColor(0xDDD6F3), line: 1.1)
        }
        return shapes.transformed(offset: origin)
    }

    // MARK: - 풍경 창

    /// 풍경 창의 꾸밈: 창밖 그림보다 먼저 그리는 것(커튼 봉·창틀)과 나중에 그리는 것(창살·커튼·창턱·작은 화분).
    /// 낮 색으로 만들고, 밤에는 부르는 쪽이 `lit(.night)`으로 칠합니다.
    static func windowDressing(_ frame: MapRect) -> (back: [ArtShape], front: [ArtShape]) {
        let x = frame.x, y = frame.y, w = frame.width, h = frame.height
        let ix = x + 7, iy = y + 7, iw = w - 14, ih = h - 14
        let rod = y - 6
        let back: [ArtShape] = [
            .line("M\(x - 11),\(rod) L\(x + w + 11),\(rod)", width: 4.2),
            .line("M\(x - 11),\(rod) L\(x + w + 11),\(rod)", width: 2, color: .swatch(.woodTop)),
            .circle(x - 12, rod, 3, fill: .swatch(.woodTop), width: 1.4),
            .circle(x + w + 12, rod, 3, fill: .swatch(.woodTop), width: 1.4),
            .rect(x, y, w, h, r: 6, fill: .swatch(.woodDark)),
        ]
        var front: [ArtShape] = [ArtShape(.rect(MapRect(ix, iy, iw, ih), radius: 3), stroke: .swatch(.ink), lineWidth: 1.2)]
        // 창살: 폭에 따라 칸을 나눕니다 (약 120pt마다)
        let panes = max(2, Int((iw / 120).rounded()))
        for pane in 1..<panes {
            front.append(.rect(ix + iw * Double(pane) / Double(panes) - 2.5, iy, 5, ih, fill: .swatch(.woodDark), width: 1.2))
        }
        // 커튼 (양옆, 가운데를 묶음)
        let cloth = Paint.color(ArtColor(0xFFF3DC))
        let fold = Paint.color(ArtColor(0xE8CFA2))
        for side in [-1.0, 1.0] {
            func px(_ d: Double) -> String { n(side < 0 ? x + d : x + w - d) }
            front += [
                .path(
                    "M\(px(-6)),\(rod) L\(px(34)),\(rod) C\(px(33)),\(y + 18) \(px(22)),\(y + 36) \(px(5)),\(y + 43) "
                        + "C\(px(12)),\(y + 52) \(px(14)),\(y + 62) \(px(13)),\(y + h - 2) L\(px(-6)),\(y + h - 2) Z", fill: cloth, width: 1.5),
                .line("M\(px(9)),\(rod + 3) C\(px(9)),\(y + 16) \(px(5)),\(y + 30) \(px(0)),\(y + 40)", width: 1.1, color: fold),
                .line("M\(px(21)),\(rod + 3) C\(px(20)),\(y + 16) \(px(13)),\(y + 32) \(px(3)),\(y + 41)", width: 1.1, color: fold),
                .line("M\(px(2)),\(y + 50) L\(px(3)),\(y + h - 5) M\(px(8)),\(y + 54) L\(px(8.6)),\(y + h - 5)", width: 1.1, color: fold),
                .rect(side < 0 ? x - 7.5 : x + w - 6.5, y + 40, 14, 6, r: 3, fill: .swatch(.alert), width: 1.3),
            ]
        }
        // 창턱과 작은 화분
        front.append(.rect(x - 9, y + h - 3, w + 18, 7.5, r: 3, fill: .swatch(.woodTop), width: 1.6))
        let spots: [Double] = w > 300 ? [0.2, 0.5, 0.8] : [0.3, 0.7]
        for (index, spot) in spots.enumerated() {
            front += tinyPot(index, at: MapPoint(x + w * spot, y + h - 3))
        }
        return (back, front)
    }

    /// 뭉게구름 (타원 셋)
    static func cloud(_ cx: Double, _ cy: Double, _ s: Double, color: ArtColor = ArtColor(0xFFFFFF), opacity: Double = 1) -> [ArtShape] {
        [
            .ellipse(cx, cy, 11 * s, 4.2 * s, fill: .color(color), opacity: opacity),
            .ellipse(cx - 4.5 * s, cy - 2.6 * s, 5.2 * s, 3.8 * s, fill: .color(color), opacity: opacity),
            .ellipse(cx + 3 * s, cy - 3.8 * s, 6.4 * s, 4.6 * s, fill: .color(color), opacity: opacity),
        ]
    }

    // MARK: - 벽에 거는 것

    /// 벽시계: 민트 테, 눈금 네 개, 10시 8분
    static func clock(at c: MapPoint) -> [ArtShape] {
        let x = c.x, y = c.y
        return [
            .circle(x, y, 18, fill: .swatch(.mint)),
            .circle(x, y, 14, fill: .swatch(.white), width: 1.3),
            .line("M\(x),\(y - 12) L\(x),\(y - 10) M\(x),\(y + 10) L\(x),\(y + 12) M\(x - 12),\(y) L\(x - 10),\(y) M\(x + 10),\(y) L\(x + 12),\(y)", width: 1.4),
            .line("M\(x),\(y) L\(x - 5.4),\(y - 4.4)", width: 2.2),
            .line("M\(x),\(y) L\(x + 6),\(y - 8.4)", width: 1.6),
            .circle(x, y, 2, fill: .swatch(.alert), width: 1),
        ]
    }

    /// 화이트보드 (왼쪽 위 모서리 기준, 폭 `OfficeLayout.whiteboardWidth` × 높이 80): 할 일 목록, 붙임쪽지, 막대그래프, 받침의 마커와 지우개
    static func whiteboard(at origin: MapPoint) -> [ArtShape] {
        let shapes: [ArtShape] = [
            .rect(0, 0, OfficeLayout.whiteboardWidth, 80, r: 6, fill: .swatch(.board)),
            // 제목과 밑줄
            .line("M14,13 H50", width: 2.2),
            .line("M14,18.6 H38", width: 1.4, color: .swatch(.alert)),
            // 할 일 세 줄 (둘은 끝냄)
            .line("M14,28 h7 v7 h-7 z M27,31.6 h38 M14,42 h7 v7 h-7 z M27,45.6 h30 M14,56 h7 v7 h-7 z M27,59.6 h42", width: 1.4),
            .line("M15,31 l2.6,2.8 l4.6,-5.8 M15,45 l2.6,2.8 l4.6,-5.8", width: 2, color: .swatch(.check)),
            // 붙임쪽지 셋
            .rect(84, 9, 17, 16, r: 1.5, fill: .swatch(.butter), width: 1.1),
            .rect(105, 15, 15, 15, r: 1.5, fill: .swatch(.pink), width: 1.1),
            .rect(89, 29, 15, 14, r: 1.5, fill: .swatch(.mint), width: 1.1),
            .line("M87,14.6 h10 M87,18.6 h7 M108,20.6 h8 M108,24.4 h5 M92,34 h8 M92,37.6 h5", width: 0.9, color: .swatch(.plateInk), opacity: 0.6),
            // 막대그래프
            .rect(86, 62, 7, 9, r: 1.2, fill: .swatch(.lavender), width: 1),
            .rect(96, 55, 7, 16, r: 1.2, fill: .swatch(.peach), width: 1),
            .rect(106, 49, 7, 22, r: 1.2, fill: .swatch(.mint), width: 1),
            .line("M82,71.4 H118", width: 1.3),
            // 받침: 지우개, 마커 둘
            .rect(18, 80, 92, 6.5, r: 3, fill: .swatch(.wallTrim)),
            .rect(26, 75, 17, 6, r: 2, fill: .swatch(.lavender), width: 1.1),
            .rect(72, 76.4, 14, 4.6, r: 2, fill: .swatch(.skyBlue), width: 1),
            .rect(90, 76.4, 14, 4.6, r: 2, fill: .swatch(.alert), width: 1),
        ]
        return shapes.transformed(offset: origin)
    }

    /// 출입문 (벽과 바닥의 경계에 섭니다): 문틀, 문짝, 창, 아래 판, 손잡이
    static func door(x door: Double) -> [ArtShape] {
        let wall = OfficeLayout.wallBottom
        let w = OfficeLayout.doorWidth
        return [
            .rect(door, wall - 112, w, 112, r: 6, fill: .swatch(.woodDark)),
            .rect(door + 7, wall - 105, w - 14, 105, r: 4, fill: .swatch(.wood)),
            // 창 (십자 창살, 빛 줄)
            .rect(door + 18, wall - 95, 36, 34, r: 5, fill: .swatch(.sky), width: 1.5),
            .line("M\(door + 36),\(wall - 95) V\(wall - 61) M\(door + 18),\(wall - 78) H\(door + 54)", width: 1.3),
            .line("M\(door + 23),\(wall - 83.5) L\(door + 29),\(wall - 90.5) M\(door + 41),\(wall - 82) L\(door + 49),\(wall - 91)", width: 1.6, color: .swatch(.white), opacity: 0.8),
            // 아래 판
            ArtShape(.rect(MapRect(door + 16, wall - 47, 40, 36), radius: 4), stroke: .swatch(.woodDark), lineWidth: 1.6),
            // 손잡이
            .rect(door + 53, wall - 60, 7.5, 12, r: 3.6, fill: .swatch(.metalDot), width: 1.1),
            .circle(door + 56.8, wall - 54, 3.2, fill: .swatch(.butter), width: 1.3),
        ]
    }

    /// 코르크 게시판 (가운데 x 기준): 쪽지와 사진을 압정으로 꽂아 둠
    static func noticeBoard(centerX x: Double) -> [ArtShape] {
        [
            .rect(x - 23, 48, 46, 38, r: 4, fill: .swatch(.woodDark)),
            .rect(x - 19.5, 51.5, 39, 31, r: 2, fill: .color(ArtColor(0xEBCFA6)), width: 1.1),
            .rect(x - 16, 55, 13, 14, r: 1, fill: .swatch(.white), width: 1),
            .line("M\(x - 13.5),\(60) h8 M\(x - 13.5),\(63.4) h6", width: 0.9, color: .swatch(.plateInk), opacity: 0.6),
            .rect(x + 1, 54, 14, 12, r: 1, fill: .swatch(.butter), width: 1),
            .rect(x - 12, 71, 12, 9, r: 1, fill: .swatch(.skyBlue), width: 1),
            .rect(x + 4, 68, 11, 12, r: 1, fill: .swatch(.white), width: 1),
            .rect(x + 5.6, 69.6, 7.8, 6.6, fill: .swatch(.mint), outline: false),
            .circle(x - 9.5, 55.6, 1.5, fill: .swatch(.alert), width: 0.8),
            .circle(x + 8, 54.8, 1.5, fill: .swatch(.check), width: 0.8),
            .circle(x - 6, 71.6, 1.5, fill: .swatch(.butter), width: 0.8),
            .circle(x + 9.5, 68.8, 1.5, fill: .swatch(.pink), width: 0.8),
        ]
    }

    /// 우산꽂이 (발 위치 기준): 접은 우산 둘
    static func umbrellaStand(at foot: MapPoint) -> [ArtShape] {
        let shapes: [ArtShape] = [
            .ellipse(0, 0, 11, 2.8, fill: .swatch(.shadow)),
            // 우산 둘 (손잡이 → 접은 천과 묶는 끈)
            .line("M-3.6,-36 V-42 q0,-3.4 -3.2,-3.4 q-3,0 -3,3", width: 1.8),
            .path("M-7.4,-12 Q-8,-28 -3.6,-37 Q0.8,-28 0.2,-12 Z", fill: .swatch(.butter), width: 1.3),
            .line("M-7.2,-24 H0", width: 1, color: .swatch(.alert)),
            .line("M4.2,-32 V-38 q0,-3.4 3.2,-3.4 q3,0 3,3", width: 1.8),
            .path("M0.6,-10 Q0,-25 4.2,-33 Q8.4,-25 7.8,-10 Z", fill: .swatch(.pink), width: 1.3),
            .line("M0.8,-21 H7.6", width: 1, color: .swatch(.white)),
            // 통
            .rect(-8, -19, 16, 19, r: 3.4, fill: .swatch(.metal)),
            .line("M-8,-13.6 H8", width: 1.1, color: .swatch(.metalDot)),
        ]
        return shapes.transformed(offset: foot)
    }

    /// 벽 선반 (왼쪽 끝 x, 선반 윗면 y, 폭 58): 책 세 권, 작은 화분, 머그잔
    static func shelf(x: Double, y: Double) -> [ArtShape] {
        var shapes: [ArtShape] = [
            .line("M\(x + 8),\(y + 5) L\(x + 8),\(y + 11) M\(x + 50),\(y + 5) L\(x + 50),\(y + 11)", width: 2),
            .rect(x, y, 58, 5.5, r: 2.4, fill: .swatch(.woodTop), width: 1.5),
            // 책 (한 권은 기대어 섬)
            .rect(x + 4, y - 15, 5, 15, r: 1, fill: .swatch(.lavender), width: 1.1),
            .rect(x + 9, y - 17, 5.6, 17, r: 1, fill: .swatch(.peach), width: 1.1),
            .rect(x + 14.6, y - 14, 5, 14, r: 1, fill: .swatch(.mint), width: 1.1),
            .path("M\(x + 21.4),\(y) L\(x + 25.6),\(y - 13.4) L\(x + 30),\(y - 12) L\(x + 25.8),\(y) Z", fill: .swatch(.butter), width: 1.1),
            // 머그잔
            .line("M\(x + 53),\(y - 6.6) q3.4,0.8 0,4", width: 1.2),
            .rect(x + 46, y - 8.4, 7.4, 8.4, r: 1.8, fill: .swatch(.white), width: 1.1),
            .rect(x + 46.6, y - 5.4, 6.2, 2, fill: .swatch(.skyBlue), outline: false),
        ]
        shapes += tinyPot(0, at: MapPoint(x + 38, y))
        return shapes
    }

    // MARK: - 책상 위 소품

    /// 서브 책상 위 소품 네 가지 (원점: 책상 상판 오른쪽 뒤, 소품이 놓이는 면)
    static func deskItem(_ kind: Int, at origin: MapPoint) -> [ArtShape] {
        var shapes: [ArtShape]
        switch ((kind % 4) + 4) % 4 {
        case 0:
            // 김 나는 머그잔
            shapes = [
                .line("M-2.6,-11.4 q-1.6,-2 0,-4 M1.4,-11.6 q1.6,-2 0,-4", width: 1, color: .swatch(.metal)),
                .line("M4,-7 q3.6,0.9 0,4.4", width: 1.2),
                .rect(-4.4, -9.4, 8.6, 9.4, r: 2, fill: .swatch(.white), width: 1.2),
                .rect(-3.8, -6, 7.4, 2.2, fill: .swatch(.pink), outline: false),
            ]
        case 1:
            // 연필꽂이
            shapes = [
                .line("M-1.8,-8 L-2.8,-15.4", width: 2.4),
                .line("M-1.8,-8 L-2.7,-14.6", width: 1.3, color: .swatch(.butter)),
                .line("M1.8,-8 L2.9,-16.4", width: 2.4),
                .line("M1.8,-8 L2.8,-15.6", width: 1.3, color: .swatch(.alert)),
                .rect(-4.2, -9, 8.4, 9, r: 2, fill: .swatch(.skyBlue), width: 1.2),
                .line("M-4.2,-6 H4.2", width: 0.9, color: .swatch(.white)),
            ]
        case 2:
            // 책 두 권 위의 사과
            shapes = [
                .rect(-8, -4.6, 17, 4.6, r: 1.4, fill: .swatch(.lavender), width: 1.1),
                .rect(-6.4, -9, 14, 4.6, r: 1.4, fill: .swatch(.butter), width: 1.1),
                .line("M0.8,-15 q0.6,-1.6 2,-2", width: 1),
                .circle(0.6, -12, 3.2, fill: .swatch(.alert), width: 1.1),
            ]
        default:
            // 액자와 선인장
            shapes = [
                .rect(-9, -11.4, 9.6, 11.4, r: 1.4, fill: .swatch(.white), width: 1.1),
                .rect(-7.4, -9.8, 6.4, 6.4, fill: .swatch(.sky), outline: false),
                .circle(-4.2, -6.2, 1.5, fill: .swatch(.butter), outline: false),
            ] + tinyPot(1, at: .zero).transformed(scale: 0.8, offset: MapPoint(5, 0))
        }
        return shapes.transformed(offset: origin)
    }
}
