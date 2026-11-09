import Foundation
import OfficeCore
import Testing

@testable import OfficeStage

/// M6(7): 시스템 "대비 증가"
@Suite("대비 증가")
struct ContrastTests {
    @Test("상태 칩: 평소 낮에는 테두리 없음, 대비 증가면 낮 흰 1.5pt, 밤 흰 85% 1.5pt")
    func pill() {
        #expect(OverlayArt.pill(text: "편집", width: 50, category: .write)[0].stroke == nil)
        let day = OverlayArt.pill(text: "편집", width: 50, category: .write, contrast: true)[0]
        #expect(day.stroke == .color(ArtColor(0xFFFFFF)))
        #expect(day.lineWidth == 1.5)
        let night = OverlayArt.pill(text: "편집", width: 50, category: .write, lighting: .night, contrast: true)[0]
        #expect(night.stroke == .color(OverlayArt.pillContrastNightEdge))
        #expect(OverlayArt.pill(text: "편집", width: 50, category: .write, lighting: .night)[0].stroke == .color(OverlayArt.pillNightEdge))
    }

    @Test("배지: \"?\" 풍선은 테두리를 먼저 깔고, ✉ 원 테두리는 굵게")
    func badge() {
        #expect(OverlayArt.badge(.reply, contrast: true).count == OverlayArt.badge(.reply).count + 2)
        #expect(OverlayArt.badge(.reply, lighting: .night, contrast: true)[0].fill == .swatch(.white))
        #expect(OverlayArt.badge(.reply, contrast: true)[0].fill == .swatch(.ink))
        #expect(OverlayArt.badge(.unread, contrast: true)[0].lineWidth > OverlayArt.badge(.unread)[0].lineWidth)
    }

    @Test("명패·행 표지·+N 테두리만 굵어진다")
    func plates() {
        var h = FloorHarness()
        h.hook(hook("SessionStart", session: "m"))
        h.run(until: 1)
        let team = h.stage.sortedTeams[0]
        let layout = OfficeLayout(rooms: [OfficeLayout.Room(team: team.id, desks: 2, hidden: 3)])
        let plates: [TeamID: [Seat: String]] = [team.id: [.main: "★ 메인", Seat(desk: 1): "서브"]]
        let normal = OfficeArt.layers(layout: layout, teams: [team], nameplates: plates)
        let boosted = OfficeArt.layers(layout: layout, teams: [team], nameplates: plates, contrast: true)
        let plateWidths = { (layers: [ArtLayer]) in layers.flatMap(\.shapes).filter { $0.fill == .swatch(.plate) && $0.stroke != nil }.map(\.lineWidth) }
        #expect(plateWidths(normal).count == 4)  // 명패 2, 행 표지, +N
        #expect(plateWidths(boosted).allSatisfy { $0 == 2.2 })
        // 다른 가구 테두리는 그대로
        let others = { (layers: [ArtLayer]) in layers.flatMap(\.shapes).filter { $0.fill != .swatch(.plate) }.map(\.lineWidth) }
        #expect(others(normal) == others(boosted))
    }
}
