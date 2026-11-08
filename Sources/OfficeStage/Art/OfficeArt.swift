import Foundation
import OfficeCore

/// 사무실 바닥·벽·가구·책상 섬 그림 (미리보기 docs/preview의 officeScene을 옮긴 것)
public enum OfficeArt {
    /// 전체 사무실 레이어. 깊이 순서대로 직원과 섞어 그리면 됩니다.
    public static func layers(layout: OfficeLayout, teams: [Team], nameplates: [TeamID: [Int: String]] = [:]) -> [ArtLayer] {
        var layers = [ArtLayer("background", depth: -.infinity, background(layout: layout))]
        layers += wallFurniture()
        for island in 0..<(layout.rows * 2) {
            let team = teams.first { $0.island == island }
            layers += self.island(island, team: team, plates: team.flatMap { nameplates[$0.id] } ?? [:])
        }
        layers += bottomZones(layout: layout)
        return layers
    }

    // MARK: - 바닥과 벽

    static func background(layout: OfficeLayout) -> [ArtShape] {
        let width = OfficeLayout.width
        let height = layout.height
        var shapes: [ArtShape] = [
            .rect(0, 0, width, 160, fill: .swatch(.wall), outline: false),
            .rect(0, 150, width, 10, fill: .swatch(.baseboard), outline: false),
            .rect(0, 160, width, height - 160, fill: .swatch(.floor), outline: false),
        ]
        var y = 196.0
        var row = 0
        while y < height {
            shapes.append(.rect(0, y, width, 2, fill: .swatch(.floorLine), outline: false))
            var x = row % 2 == 1 ? 60.0 : 150.0
            while x < width {
                shapes.append(.rect(x, y - 34, 2, 34, fill: .swatch(.floorLine), outline: false))
                x += 210
            }
            y += 36
            row += 1
        }
        // 책상 섬 러그와 휴게실 러그는 바닥에 깔리므로 배경입니다
        for island in 0..<(layout.rows * 2) {
            let center = OfficeLayout.islandCenter(island)
            shapes.append(.rect(center.x - 190, center.y - 84, 380, 114, r: 28, fill: .swatch(Swatch.teamRugs[island % 4]), outline: false, opacity: 0.55))
        }
        let b = layout.bottomZoneY
        shapes.append(.rect(640, b - 68, 306, 112, r: 30, fill: .swatch(.rugC), outline: false))
        shapes.append(.ellipse(118, b - 6, 96, 40, fill: .swatch(.rugA), opacity: 0.7))
        shapes.append(.rect(680, 162, 64, 10, r: 5, fill: .swatch(.rugC)))  // 현관 매트
        return shapes
    }

    static func wallFurniture() -> [ArtLayer] {
        var shapes: [ArtShape] = []
        // 창문 두 개
        for x in [285.0, 395.0] {
            let y = 30.0
            shapes += [
                .rect(x, y, 96, 84, r: 8, fill: .swatch(.wallTrim)),
                .rect(x + 6, y + 6, 84, 72, r: 5, fill: .swatch(.sky), outline: false),
                .rect(x + 6, y + 48, 84, 30, r: 5, fill: .swatch(.sky2), outline: false),
                .ellipse(x + 30, y + 28, 14, 6, fill: .swatch(.cloud)),
                .ellipse(x + 40, y + 24, 10, 7, fill: .swatch(.cloud)),
                .ellipse(x + 66, y + 44, 11, 5, fill: .swatch(.cloud), opacity: 0.8),
                .rect(x + 46, y + 6, 4, 72, fill: .swatch(.wallTrim), outline: false),
                .rect(x - 4, y + 82, 104, 8, r: 3, fill: .swatch(.wallTrim)),
            ]
        }
        shapes += plant(at: MapPoint(339, 113), scale: 0.62)
        // 책장
        shapes += [
            .rect(30, 34, 132, 122, r: 6, fill: .swatch(.woodDark)),
            .rect(38, 42, 116, 106, r: 3, fill: .swatch(.wood), outline: false),
        ]
        let books: [Swatch] = [.mint, .peach, .lavender, .butter, .skyBlue, .pink]
        for (row, baseY) in [72.0, 108.0, 144.0].enumerated() {
            var x = 44.0
            for i in 0..<9 {
                let w = 8.0 + Double((i * 7 + row * 3) % 5)
                let h = 20.0 + Double((i * 5 + row * 2) % 4) * 3
                if x + w > 150 { break }
                shapes.append(.rect(x, baseY - h, w, h, r: 1.5, fill: .swatch(books[(i + row * 2) % 6]), width: 1.3))
                x += w + 1.5
            }
            shapes.append(.rect(38, baseY, 116, 4, fill: .swatch(.woodDark), outline: false))
        }
        // 시계
        shapes += [
            .circle(222, 62, 18, fill: .swatch(.white)),
            .line("M222,62 L222,51 M222,62 L230,66"),
            .circle(222, 62, 2, fill: .swatch(.ink), outline: false),
        ]
        // 화이트보드
        shapes += [
            .rect(512, 36, 128, 80, r: 6, fill: .swatch(.board)),
            .line("M528,54 h8 v8 h-8 z M542,58 h56 M528,72 h8 v8 h-8 z M542,76 h44 M528,90 h8 v8 h-8 z M542,94 h66", width: 1.5),
            .line("M529,57 l3,3 l5,-6 M529,75 l3,3 l5,-6", width: 2, color: .swatch(.check)),
            .rect(532, 116, 88, 6, r: 3, fill: .swatch(.wallTrim)),
            .rect(600, 111, 12, 5, r: 2, fill: .swatch(.alert), outline: false),
        ]
        // 출입문
        shapes += [
            .rect(676, 48, 72, 112, r: 6, fill: .swatch(.woodDark)),
            .rect(684, 56, 56, 104, r: 4, fill: .swatch(.wood)),
            .rect(696, 68, 32, 30, r: 4, fill: .swatch(.sky)),
            .circle(730, 114, 3.5, fill: .swatch(.butter)),
            .rect(690, 30, 44, 14, r: 4, fill: .swatch(.plate), width: 1.3),
            .text("입구", 712, 40.5, size: 8),
        ]
        // 서버랙 두 대
        let leds: [Swatch] = [.mint, .skyBlue, .butter]
        for (rackIndex, x) in [790.0, 858.0].enumerated() {
            shapes.append(.rect(x, 20, 64, 140, r: 7, fill: .swatch(.rack)))
            for k in 0..<6 {
                let y = 32.0 + Double(k) * 20
                shapes += [
                    .rect(x + 8, y, 48, 14, r: 3, fill: .swatch(.rackDark), outline: false),
                    .circle(x + 16, y + 7, 2.2, fill: .swatch(leds[(k + rackIndex) % 3]), outline: false),
                    .rect(x + 24, y + 5, 24, 3, r: 1.5, fill: .swatch(.white), outline: false, opacity: 0.25),
                ]
            }
        }
        return [ArtLayer("wall", depth: -.infinity, shapes)]
    }

    // MARK: - 책상 섬

    /// 좌석별 의자 색
    static let chairColors: [UInt32] = [0x7FC9B3, 0xF0A58B, 0xB6A6E4, 0xE9CB6C]

    static func island(_ island: Int, team: Team?, plates: [Int: String]) -> [ArtLayer] {
        let center = OfficeLayout.islandCenter(island)
        var layers: [ArtLayer] = []
        for (index, offset) in OfficeLayout.deskOffsets.enumerated() {
            let x = center.x + offset
            let y = center.y
            // 의자는 직원 뒤에 (깊이 y-1)
            layers.append(ArtLayer("chair-\(island)-\(index)", depth: y - 1, [
                .rect(x - 17, y - 60, 34, 36, r: 11, fill: .color(ArtColor(chairColors[(index + island) % 4]))),
            ]))
            var desk: [ArtShape] = [
                .rect(x - 41, y - 33, 82, 11, r: 4, fill: .swatch(.woodTop)),
                .rect(x - 41, y - 24, 82, 27, r: 5, fill: .swatch(.wood)),
                .rect(x - 40, y - 46, 26, 14, r: 3, fill: .swatch(.metal)),
                .circle(x - 27, y - 39, 2, fill: .swatch(.metalDot), outline: false),
            ]
            if let name = plates[index] {
                let width = Double(min(max(name.count, 4), 16)) * 5 + 12
                desk += [
                    .rect(x - width / 2, y - 17, width, 11, r: 3, fill: .swatch(.plate), width: 1.2),
                    .text(name, x, y - 9.2, size: 7),
                ]
            }
            if index == 0 {
                desk += plant(at: MapPoint(x + 29, y - 33), scale: 0.4)
            }
            layers.append(ArtLayer("desk-\(island)-\(index)", depth: y + 3, desk))
        }
        if let team {
            let label = team.name
            let width = Double(label.count) * 6.4 + 30
            layers.append(ArtLayer("sign-\(island)", depth: -.infinity, [
                .rect(center.x - width / 2, center.y + 35, width, 20, r: 10, fill: .swatch(.plate), width: 1.4),
                .circle(center.x - width / 2 + 11, center.y + 45, 4, fill: .swatch(Swatch.teamColors[team.colorIndex % 4]), width: 1),
                .text(label, center.x + 7, center.y + 48.6, size: 10, color: .swatch(.ink)),
            ]))
        }
        return layers
    }

    // MARK: - 리서치 코너와 휴게실

    static func bottomZones(layout: OfficeLayout) -> [ArtLayer] {
        let b = layout.bottomZoneY
        let shift = MapPoint(0, b - 520)
        var layers: [ArtLayer] = []
        layers.append(ArtLayer("globe", depth: b, [
            .rect(58, 480, 8, 40, fill: .swatch(.woodDark)),
            .ellipse(62, 520, 16, 4.5, fill: .swatch(.woodDark), outline: true),
            .circle(62, 462, 20, fill: .swatch(.skyBlue)),
            .path("M50,454 C56,448 64,450 66,456 C64,462 56,460 52,464 C48,462 47,458 50,454 Z M68,468 C72,466 77,470 74,475 C70,476 67,473 68,468 Z", fill: .swatch(.mint), width: 1.4),
            .line("M40,470 Q58,490 76,482", width: 1.6),
        ].transformed(offset: shift)))
        layers.append(ArtLayer("lamp", depth: b - 50, [
            .rect(26, 408, 4, 62, fill: .swatch(.rack)),
            .path("M16,408 L40,408 L35,390 L21,390 Z", fill: .swatch(.butter)),
            .ellipse(28, 470, 10, 3, fill: .swatch(.rack), outline: true),
        ].transformed(offset: shift)))
        layers.append(ArtLayer("lounge-plant", depth: b - 20, plant(at: MapPoint(668, 500), scale: 1).transformed(offset: shift)))
        layers.append(ArtLayer("coffee", depth: b - 12, [
            .rect(880, 464, 60, 44, r: 6, fill: .swatch(.wood)),
            .rect(894, 426, 32, 38, r: 6, fill: .swatch(.rack)),
            .rect(901, 434, 18, 8, r: 2, fill: .swatch(.mint), outline: false),
            .rect(904, 450, 12, 10, r: 2, fill: .swatch(.white)),
        ].transformed(offset: shift)))
        // 소파 등받이는 앉은 직원 뒤, 앉는 판과 팔걸이는 앞
        layers.append(ArtLayer("sofa-back", depth: b - 30, [
            .rect(734, 472, 124, 38, r: 16, fill: .color(ArtColor(0x9C8FCF))),
        ].transformed(offset: shift)))
        layers.append(ArtLayer("sofa-front", depth: b + 3, [
            .rect(738, 500, 116, 26, r: 10, fill: .color(ArtColor(0xB3A7E2))),
            .rect(726, 484, 18, 44, r: 9, fill: .color(ArtColor(0x9C8FCF))),
            .rect(848, 484, 18, 44, r: 9, fill: .color(ArtColor(0x9C8FCF))),
        ].transformed(offset: shift)))
        return layers
    }

    /// 화분 (발 위치 기준)
    static func plant(at origin: MapPoint, scale: Double) -> [ArtShape] {
        [
            .path("M0,-20 C-16,-24 -22,-44 -12,-52 C-6,-40 -2,-32 0,-20 Z", fill: .color(ArtColor(0x86C9A9))),
            .path("M0,-20 C14,-28 20,-46 10,-54 C4,-42 1,-32 0,-20 Z", fill: .swatch(.mint)),
            .path("M0,-20 C-4,-34 -2,-50 2,-58 C6,-46 4,-32 0,-20 Z", fill: .color(ArtColor(0x7CBF9E))),
            .path("M-12,-22 H12 L9,0 H-9 Z", fill: .swatch(.pot)),
        ].transformed(scale: scale, offset: origin)
    }
}
