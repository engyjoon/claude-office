import Foundation
import OfficeCore
import Testing

@testable import OfficeStage

/// M6(8): 메인 책상 밑 폴더 이름 표지 (행 색 칩)
@Suite("행 표지: 행 색 칩")
struct RowSignTests {
    private static let desk = MapPoint(OfficeLayout.deskX(0), OfficeLayout.firstDeskY)

    private func parts(_ shapes: [ArtShape]) -> (box: MapRect, text: String, size: Double, bold: Bool, at: MapPoint) {
        guard case .rect(let box, _) = shapes[0].geometry,
              case .text(let text, let at, let size, let bold, _, _) = shapes.last!.geometry
        else { fatalError("행 표지 모양이 다름") }
        return (box, text, size, bold, at)
    }

    @Test("10.5pt 굵은 글자, 높이 20, 행 색 바탕, 책상 앞판 아래에서 시작")
    func shape() {
        let shapes = OfficeArt.sign("claude-office", at: Self.desk, color: 1)
        let p = parts(shapes)
        #expect(p.text == "claude-office")
        #expect(p.size == 10.5 && p.bold)
        #expect(p.box.height == 20)
        #expect(p.box.x == Self.desk.x - OfficeLayout.deskWidth / 2)
        #expect(p.box.y > Self.desk.y + 3)  // 책상 앞판 아래 끝보다 아래
        #expect(shapes[0].fill == .swatch(.peach))
        #expect(shapes[0].lineWidth == 1.4)
        // 칩 폭은 굵은 글자 폭 + 아이콘 자리 + 뒤 여백
        #expect(p.box.width >= TextMetrics.width(p.text, size: 10.5, bold: true) + 20 + 10 - 0.01)
        #expect(p.at.x == p.box.x + 20)
    }

    @Test("긴 폴더 이름은 굵은 글자 폭 136 안에서 …로 줄이고, 칩은 옆 서브 책상 앞판 아래에 머문다")
    func longName() {
        let p = parts(OfficeArt.sign("enterprise-mobile-gateway-admin-console", at: Self.desk, color: 0))
        #expect(p.text.hasSuffix("…"))
        #expect(p.text.count >= 18)
        #expect(TextMetrics.width(p.text, size: 10.5, bold: true) <= 136)
        #expect(p.box.maxX <= Self.desk.x - OfficeLayout.deskWidth / 2 + 136 + 30)
    }

    @Test("밤: 행 색은 낮 색 그대로(섞지 않음), 테두리·글자는 밤 잉크, 팔레트 이름은 남기지 않음")
    func night() {
        let shapes = OfficeArt.sign("claude-office", at: Self.desk, color: 0, lighting: .night)
        #expect(shapes[0].fill == .color(Swatch.mint.color))
        let ink = Paint.color(NightPalette.color(Swatch.ink.color))
        #expect(shapes[0].stroke == ink)
        #expect(shapes.last!.fill == ink)
        #expect(!shapes.flatMap { [$0.fill, $0.stroke].compactMap { $0 } }.contains { if case .swatch = $0 { true } else { false } })
        // 사무실 그림 안에서도 섞이지 않은 행 색이 남음
        var h = FloorHarness()
        h.hook(hook("SessionStart", session: "m"))
        h.run(until: 1)
        let team = h.stage.sortedTeams[0]
        let layers = OfficeArt.layers(layout: h.stage.layout, teams: [team], lighting: .night)
        let sign = layers.first { $0.name == "row-sign-\(team.id.raw)" }
        #expect(sign?.shapes[0].fill == .color(Swatch.teamColors[team.colorIndex % 4].color))
    }

    @Test("미니 사무실 크롭 안에 다 들어감")
    func fitsMini() {
        let p = parts(OfficeArt.sign("claude-coworker", at: Self.desk, color: 2))
        #expect(p.box.maxY <= MiniOffice.bottom - 8)
    }
}
