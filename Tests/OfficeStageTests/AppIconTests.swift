import Foundation
import OfficeCore
import Testing

@testable import OfficeStage

@Suite("앱 아이콘 그림 (M6(3))")
struct AppIconTests {
    @Test("바탕은 1024 캔버스 가운데의 824 둥근 사각형 (macOS 아이콘 격자)")
    func plateFollowsGrid() {
        let plate = AppIconArt.plate
        #expect(plate.width == 824 && plate.height == 824)
        #expect(plate.x + plate.width / 2 == AppIconArt.canvas / 2)
        #expect(plate.y + plate.height / 2 == AppIconArt.canvas / 2)
    }

    @Test("머리(얼굴 원)는 바탕 안에 다 들어간다")
    func faceInsidePlate() {
        let plate = AppIconArt.plate
        for detail in AppIconArt.Detail.allCases {
            let faces = AppIconArt.groups(detail).flatMap(\.shapes).filter { $0.fill == .skin }
            guard case .circle(let c, let r) = faces.first?.geometry else {
                Issue.record("얼굴 원이 없음 (\(detail))")
                continue
            }
            #expect(c.x - r > plate.x && c.x + r < plate.x + plate.width && c.y - r > plate.y)
        }
    }

    @Test("16·32px용 그림은 선이 32 이상 (32px에서 1px)이고 볼터치·별 배지를 뺀다")
    func smallIsSimplified() {
        let small = AppIconArt.groups(.small).flatMap(\.shapes)
        #expect(small.allSatisfy { $0.stroke == nil || $0.lineWidth >= 32 })
        #expect(!small.contains { $0.fill == .swatch(.blush) || $0.fill == .swatch(.butter) })
        #expect(AppIconArt.groups(.full).flatMap(\.shapes).contains { $0.fill == .swatch(.butter) })
    }

    @Test("SVG는 바탕 안으로 잘라 그린다")
    func svgClipsToPlate() {
        let svg = SVGRenderer.appIcon(.full)
        #expect(svg.hasPrefix("<svg") && svg.hasSuffix("</svg>"))
        #expect(svg.contains("clip-path=\"url(#plate)\""))
        #expect(svg.contains(AppIconArt.plateFill.hex))
    }
}
