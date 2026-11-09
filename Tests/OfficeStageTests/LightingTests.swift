import Foundation
import OfficeCore
import Testing

@testable import OfficeStage

/// 그림 데이터에 쓰인 칠할 색을 모두 모읍니다
private func paints(_ layers: [ArtLayer]) -> [Paint] {
    layers.flatMap(\.shapes).flatMap { [$0.fill, $0.stroke].compactMap { $0 } }
}

private func rgbs(_ layers: [ArtLayer]) -> Set<UInt32> {
    Set(paints(layers).map { SVGRenderer.resolve($0, colors: nil).rgb })
}

/// 메인 한 명이 출근해 자기 책상에 앉은 사무실
private func seatedOffice() -> StageHarness {
    var h = StageHarness()
    h.hook(hook("SessionStart"))
    h.hook(hook("UserPromptSubmit", #""prompt":"x""#), at: 1)
    h.run(until: 20)
    return h
}

@Suite("밤 조명 (M6(6))")
struct LightingTests {
    @Test("밤 팔레트: 넓은 면은 고른 색, 그 밖은 밤 톤과 섞고, 불투명도는 그대로")
    func palette() {
        #expect(NightPalette.color(Swatch.wall.color).rgb == 0x3E4468)
        #expect(NightPalette.color(Swatch.floor.color).rgb == 0x5B4F63)
        // 명패는 밝게 남아 이름이 읽힘
        #expect(NightPalette.color(Swatch.plate.color).rgb == 0xEFE7DA)
        // 화면 불빛은 그대로
        #expect(NightPalette.color(Swatch.screenGlow.color) == Swatch.screenGlow.color)
        // 표에 없는 색: 0x000000과 밤 톤(0x232846)을 45% 섞음 (반올림)
        #expect(NightPalette.color(ArtColor(0x000000)).rgb == 0x101220)
        #expect(NightPalette.color(ArtColor(0xD9B48F, alpha: 0.5)).alpha == 0.5)
        // 직원 부위 색은 바꾸지 않음
        #expect(NightPalette.paint(.skin) == .skin)
        #expect(Swatch.wall.color.lit(.day) == Swatch.wall.color)
    }

    @Test("낮 그림은 조명 인자가 없을 때와 똑같다")
    func dayUnchanged() {
        let layout = OfficeLayout()
        #expect(OfficeArt.layers(layout: layout, teams: [], lighting: .day) == OfficeArt.layers(layout: layout, teams: []))
        #expect(CharacterArt.shadow(.day) == CharacterArt.shadow)
        #expect(OverlayArt.pill(text: "편집 중", width: 60, category: .write)
            == OverlayArt.pill(text: "편집 중", width: 60, category: .write, lighting: .day))
    }

    @Test("밤 가구: 팔레트 이름 대신 밤 색으로 바꿔 두어 굽기 캐시가 낮·밤을 구분하고, 낮의 벽·바닥 색은 남지 않는다")
    func nightLayers() {
        let layout = OfficeLayout()
        let night = OfficeArt.layers(layout: layout, teams: [], lighting: .night)
        #expect(!paints(night).contains { if case .swatch = $0 { true } else { false } })
        let colors = rgbs(night)
        for day in [Swatch.wall, .floor, .floorLine, .baseboard] { #expect(!colors.contains(day.color.rgb)) }
        #expect(colors.contains(0x3E4468))
        // 창밖: 정원 하늘 대신 밤하늘과 달
        #expect(!colors.contains(0xDDF0F7))
        #expect(colors.contains(0x27315E))
        #expect(colors.contains(0xFFF1B8))
        // 휴게 공간 스탠드는 밤에만, 휴게 공간이 있을 때만
        #expect(night.contains { $0.name == "floor-lamp" })
        #expect(!OfficeArt.layers(layout: layout, teams: []).contains { $0.name == "floor-lamp" })
        #expect(!OfficeArt.layers(layout: layout, teams: [], lounge: false, lighting: .night).contains { $0.name == "floor-lamp" })
        // 순서: 바탕이 맨 앞(맨 뒤에 그림), 그다음 벽
        #expect(night.first?.name == "background")
    }

    @Test("책상 불빛은 사람이 있는 책상에만 켜진다")
    func litDesks() throws {
        var h = seatedOffice()
        let lead = try #require(h.stage.actors.values.first { $0.agent.isMain })
        #expect(!lead.isWalking)
        let lit = OfficeArt.litDesks(stage: h.stage)
        #expect(lit.count == 1)
        #expect(lit.first.map { $0.distance(to: lead.position) < 2 } == true)
        #expect(!OfficeArt.deskLight(at: lit[0]).isEmpty)
        // 퇴근하면 불이 꺼짐
        h.hook(hook("SessionEnd", #""reason":"exit""#), at: 21)
        h.run(until: 60)
        #expect(OfficeArt.litDesks(stage: h.stage).isEmpty)
    }

    @Test("밤에는 발밑 그림자가 빛 웅덩이로, 상태 칩에 옅은 테두리가 붙는다")
    func characterAndOverlay() throws {
        let pool = CharacterArt.shadow(.night)
        #expect(pool != CharacterArt.shadow)
        #expect(pool.allSatisfy { $0.fill.map { SVGRenderer.resolve($0, colors: nil).rgb } == 0xFFE3A3 })
        let pill = OverlayArt.pill(text: "편집 중", width: 60, category: .write, lighting: .night)
        #expect(pill.first?.stroke == .color(OverlayArt.pillNightEdge))
        #expect(OverlayArt.pill(text: "편집 중", width: 60, category: .write).first?.stroke == nil)

        var h = seatedOffice()
        h.hook(tool("PreToolUse", "Edit", "e1", #"{"file_path":"/x/Stage.swift"}"#), at: 21)
        h.run(until: 23)
        let items = Overlay.items(for: h.stage, options: OverlayOptions(lighting: .night))
        let chip = try #require(items.first { $0.kind == .pill })
        #expect(chip.shapes.first?.stroke == .color(OverlayArt.pillNightEdge))
    }

    @Test("SVG 스냅숏: 밤이면 밤 벽색·책상 불빛·빛 웅덩이가 있고, 낮 그림에는 밤 색이 없다")
    func svgSnapshot() {
        let h = seatedOffice()
        let night = SVGRenderer.render(stage: h.stage, lighting: .night)
        #expect(night.contains("#3E4468"))
        #expect(night.contains("#FFD98A"))  // 스탠드 불빛
        #expect(night.contains("#FFE3A3"))  // 발밑 빛 웅덩이·스탠드 갓
        let day = SVGRenderer.render(stage: h.stage)
        #expect(!day.contains("#3E4468"))
        #expect(!day.contains("#FFD98A"))
        #expect(day.contains(Swatch.wall.color.hex))
    }
}
