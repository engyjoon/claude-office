import Foundation
import OfficeCore
import Testing

@testable import OfficeStage

@Suite("그림 데이터: 초상과 명패")
struct PortraitAndPlateTests {
    @Test("초상의 원·타원·사각형은 모두 초상 틀 안에서 시작한다 (가슴 아래는 잘려도 됨)")
    func portraitFitsFrame() {
        let frame = CharacterArt.portraitFrame
        for style in 0..<Appearance.hairStyleCount {
            for accessory in [nil] + Accessory.allCases.map(Optional.some) {
                let appearance = Appearance(skinTone: 0, hairStyle: style, hairColor: 0, topColor: 0, accessory: accessory, voice: 0)
                for shape in CharacterArt.portrait(appearance, isLead: true) {
                    switch shape.geometry {
                    case .circle(let c, let r):
                        #expect(c.x - r >= frame.x - 0.5 && c.x + r <= frame.maxX + 0.5 && c.y - r >= frame.y - 0.5)
                    case .ellipse(let c, let rx, let ry):
                        #expect(c.x - rx >= frame.x - 0.5 && c.x + rx <= frame.maxX + 0.5 && c.y - ry >= frame.y - 0.5)
                    case .rect(let rect, _):
                        #expect(rect.x >= frame.x - 0.5 && rect.maxX <= frame.maxX + 0.5 && rect.y >= frame.y - 0.5)
                    default:
                        break
                    }
                }
            }
        }
    }

    @Test("팀장 별 배지가 초상 틀 안에 보인다")
    func badgeVisible() {
        let frame = CharacterArt.portraitFrame
        // 별 중심은 몸 기준 (7, -31) → 머리 기준 (7, -31 - headOrigin.y)
        let star = MapPoint(7, -31 - CharacterArt.headOrigin.y)
        #expect(star.y + 4.6 <= frame.maxY)
    }

    @Test("팀장 초상에만 가슴의 별 배지가 있다")
    func leadBadge() {
        let appearance = Appearance.make(key: "lead@x", kind: .lead)
        let star: (ArtShape) -> Bool = { $0.fill == .swatch(.butter) }
        #expect(CharacterArt.portrait(appearance, isLead: true).contains(where: star))
        #expect(!CharacterArt.portrait(appearance, isLead: false).contains(where: star))
    }

    @Test("명패 글자는 책상 폭에 맞추고, 넘치면 …로 줄인다")
    func plateFitting() {
        let short = OfficeArt.fitted("★ 팀장", size: 9.5, maxWidth: 66)
        #expect(short.0 == "★ 팀장")
        #expect(OfficeArt.fitted("code-reviewer", size: 9.5, maxWidth: 66).0 == "code-reviewer")
        let long = OfficeArt.fitted("very-long-custom-agent-name", size: 9.5, maxWidth: 66)
        #expect(long.0.hasSuffix("…"))
        #expect(long.1 <= 66)
    }

    @Test("명패는 책상 앞판 가운데보다 조금 위, 글자는 명패 가운데보다 아주 조금 아래에 놓인다")
    func plateCentered() throws {
        let layers = OfficeArt.island(0, team: nil, plates: [0: "★ 팀장"])
        let desk = try #require(layers.first { $0.name == "desk-0-0" })
        let box = try #require(desk.shapes.compactMap { shape -> MapRect? in
            if case .rect(let rect, _) = shape.geometry, shape.fill == .swatch(.plate) { return rect }
            return nil
        }.first)
        let text = try #require(desk.shapes.compactMap { shape -> (MapPoint, TextBaseline)? in
            if case .text(_, let at, _, _, _, let baseline) = shape.geometry { return (at, baseline) }
            return nil
        }.first)
        #expect(text.1 == .central)
        #expect(abs(text.0.y - (box.y + box.height / 2 + 0.5)) < 0.01)
        // 명패는 책상 앞판에서 보이는 부분(상판 아래 ~ 앞판 바닥)의 가운데보다 1pt 위에 달리고, 상판을 덮지 않는다
        let rects = desk.shapes.compactMap { shape -> (MapRect, Paint?)? in
            if case .rect(let rect, _) = shape.geometry { return (rect, shape.fill) }
            return nil
        }
        let top = try #require(rects.first { $0.1 == .swatch(.woodTop) }?.0)
        let front = try #require(rects.first { $0.1 == .swatch(.wood) }?.0)
        let visibleMid = (top.maxY + front.maxY) / 2
        #expect(abs((box.y + box.height / 2) - (visibleMid - 1.0)) < 0.01)
        #expect(box.y > top.maxY)
        #expect(box.maxY < front.maxY)
    }

    @Test("창 비율이 달라 남는 곳까지 벽과 바닥을 이어 그린다")
    func backgroundFillsExtent() throws {
        let layout = OfficeLayout()
        let extent = MapRect(-120, 0, OfficeLayout.width + 240, layout.height + 200)
        let rects = OfficeArt.background(layout: layout, extent: extent).compactMap { shape -> (MapRect, Paint?)? in
            if case .rect(let rect, _) = shape.geometry { return (rect, shape.fill) }
            return nil
        }
        let wall = try #require(rects.first { $0.1 == .swatch(.wall) }?.0)
        let floor = try #require(rects.first { $0.1 == .swatch(.floor) }?.0)
        #expect(wall.x <= extent.x && wall.maxX >= extent.maxX)
        #expect(floor.x <= extent.x && floor.maxX >= extent.maxX && floor.maxY >= extent.maxY)
        // 바닥 줄눈도 사무실 밖까지 이어진다
        #expect(rects.contains { $0.1 == .swatch(.floorLine) && $0.0.x < 0 })
        #expect(rects.contains { $0.1 == .swatch(.floorLine) && $0.0.y > layout.height })
    }
}
