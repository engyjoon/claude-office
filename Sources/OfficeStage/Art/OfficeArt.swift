import Foundation
import OfficeCore

/// 사무실 바닥·벽·가구·행 그림 (미리보기 docs/preview의 officeScene을 바탕으로 M5(1) 행 배치에 맞춘 것)
public enum OfficeArt {
    /// 바닥에 깔리는 것과 움직이지 않는 가구. 깊이 순서대로 직원과 섞어 그리면 됩니다.
    /// - Parameters:
    ///   - teams: 행마다 이름·색을 찾을 목록
    ///   - nameplates: 책상 명패 (행 → 책상 → 이름)
    ///   - extent: 화면에 보이는 영역(지도 좌표). 사무실보다 넓으면 남는 곳까지 벽과 바닥을 이어 그립니다.
    ///     nil이면 사무실 크기(0, 0, width, height)만 그립니다.
    public static func layers(
        layout: OfficeLayout, teams: [Team], nameplates: [TeamID: [Seat: String]] = [:], extent: MapRect? = nil
    ) -> [ArtLayer] {
        var layers = [ArtLayer("background", depth: -.infinity, background(layout: layout, teams: teams, extent: extent))]
        layers += wallFurniture(layout)
        for row in layout.rows {
            let team = teams.first { $0.id == row.team }
            layers += self.row(row, team: team, plates: nameplates[row.team] ?? [:])
        }
        layers += lounge()
        return layers
    }

    /// 시간에 따라 움직이는 가구: 안마 의자 등판 롤러, 긴 명령을 기다리는 직원의 모니터 진행 표시.
    /// 매 프레임 다시 계산합니다 (렌더러는 바뀐 경우에만 다시 그리면 됩니다).
    public static func liveLayers(stage: Stage) -> [ArtLayer] {
        let time = stage.time
        var layers: [ArtLayer] = []
        for (index, seat) in OfficeLayout.massageSeats.enumerated() {
            let massaged = stage.actors.values.contains { actor in
                actor.place?.key == "massageChair:\(index)" && !actor.isWalking && actor.position.distance(to: seat) < 1
            }
            let name = index == 0 ? "massage-roller" : "massage-roller-\(index + 1)"
            layers.append(ArtLayer(name, depth: seat.y - 0.5, massageRoller(at: seat, time: massaged ? time : nil)))
        }
        for actor in stage.sortedActors where actor.pose == .watching && actor.seated && !actor.isWalking {
            layers.append(ArtLayer("monitor-\(actor.id.raw)", depth: actor.position.y + 3.5, monitorProgress(at: actor.position, time: time, seed: actor.id.raw)))
        }
        return layers
    }

    // MARK: - 바닥과 벽

    static func background(layout: OfficeLayout, teams: [Team] = [], extent: MapRect? = nil) -> [ArtShape] {
        let area = extent ?? MapRect(0, 0, layout.width, layout.height)
        let left = min(area.x, 0)
        let right = max(area.maxX, layout.width)
        let top = min(area.y, 0)
        let bottom = max(area.maxY, layout.height)
        let width = right - left
        var shapes: [ArtShape] = [
            .rect(left, top, width, 160 - top, fill: .swatch(.wall), outline: false),
            .rect(left, 150, width, 10, fill: .swatch(.baseboard), outline: false),
            .rect(left, 160, width, bottom - 160, fill: .swatch(.floor), outline: false),
        ]
        // 바닥 줄눈: 가로줄은 36pt마다, 세로줄은 210pt마다 한 줄씩 엇갈립니다 (사무실 밖으로도 같은 무늬)
        var y = 196.0
        var row = 0
        let limit = extent == nil ? bottom : bottom + 36  // 화면을 채울 때는 맨 아래 반쪽 줄까지
        while y < limit {
            shapes.append(.rect(left, y, width, 2, fill: .swatch(.floorLine), outline: false))
            var x = row % 2 == 1 ? 60.0 : 150.0
            while x - 210 >= left { x -= 210 }
            while x < right {
                shapes.append(.rect(x, y - 34, 2, 34, fill: .swatch(.floorLine), outline: false))
                x += 210
            }
            y += 36
            row += 1
        }
        // 행 러그: 메인 색 (책상 수만큼)
        for row in layout.rows {
            let color = teams.first { $0.id == row.team }?.colorIndex ?? 0
            let from = OfficeLayout.deskX(0) - 52
            let to = row.endX + 11
            shapes.append(.rect(from, row.deskY - 84, to - from, 112, r: 26, fill: .swatch(Swatch.teamRugs[color % 4]), outline: false, opacity: 0.5))
        }
        // 휴게 공간 러그(소파 구역), 안마 구역 러그, 현관 매트
        let sofas = OfficeLayout.sofas
        shapes.append(.rect(6, 176, sofas[sofas.count - 1].maxX + 8 - 6, 78, r: 26, fill: .swatch(.rugC), outline: false, opacity: 0.8))
        let m = OfficeLayout.massageArea
        shapes.append(.rect(m.x, m.y + 4, m.width, m.height - 6, r: 22, fill: .color(ArtColor(0xD4E2F2)), outline: false, opacity: 0.85))
        shapes.append(.rect(layout.doorX + 4, 162, 64, 10, r: 5, fill: .swatch(.rugC)))
        return shapes
    }

    static func wallFurniture(_ layout: OfficeLayout) -> [ArtLayer] {
        var shapes: [ArtShape] = []
        // 휴게 공간 벽: 액자와 시계
        shapes += [
            .rect(28, 40, 92, 66, r: 5, fill: .swatch(.woodDark)),
            .rect(35, 47, 78, 52, r: 3, fill: .swatch(.sky2), outline: false),
            .path("M35,99 L58,72 L74,88 L88,76 L113,99 Z", fill: .swatch(.mint), width: 1.4),
            .circle(98, 60, 6, fill: .swatch(.butter), width: 1.2),
            .circle(166, 70, 18, fill: .swatch(.white)),
            .line("M166,70 L166,59 M166,70 L174,74"),
            .circle(166, 70, 2, fill: .swatch(.ink), outline: false),
        ]
        // 책장 (휴게 공간 오른쪽)
        let shelfX = OfficeLayout.bookshelfX
        shapes += [
            .rect(shelfX, 34, 132, 122, r: 6, fill: .swatch(.woodDark)),
            .rect(shelfX + 8, 42, 116, 106, r: 3, fill: .swatch(.wood), outline: false),
        ]
        let books: [Swatch] = [.mint, .peach, .lavender, .butter, .skyBlue, .pink]
        for (row, baseY) in [72.0, 108.0, 144.0].enumerated() {
            var x = shelfX + 14
            for i in 0..<9 {
                let w = 8.0 + Double((i * 7 + row * 3) % 5)
                let h = 20.0 + Double((i * 5 + row * 2) % 4) * 3
                if x + w > shelfX + 120 { break }
                shapes.append(.rect(x, baseY - h, w, h, r: 1.5, fill: .swatch(books[(i + row * 2) % 6]), width: 1.3))
                x += w + 1.5
            }
            shapes.append(.rect(shelfX + 8, baseY, 116, 4, fill: .swatch(.woodDark), outline: false))
        }
        // 창문 (책장과 화이트보드 사이에 들어가는 만큼)
        for x in layout.windowXs {
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
        if let last = layout.windowXs.last { shapes += plant(at: MapPoint(last + 112, 150), scale: 0.55) }
        // 화이트보드
        let board = layout.whiteboardX - 512
        shapes += [
            .rect(512 + board, 36, 128, 80, r: 6, fill: .swatch(.board)),
            .line("M528,54 h8 v8 h-8 z M542,58 h56 M528,72 h8 v8 h-8 z M542,76 h44 M528,90 h8 v8 h-8 z M542,94 h66", width: 1.5)
                .transformed(offset: MapPoint(board, 0)),
            .line("M529,57 l3,3 l5,-6 M529,75 l3,3 l5,-6", width: 2, color: .swatch(.check)).transformed(offset: MapPoint(board, 0)),
            .rect(532 + board, 116, 88, 6, r: 3, fill: .swatch(.wallTrim)),
            .rect(600 + board, 111, 12, 5, r: 2, fill: .swatch(.alert), outline: false),
        ]
        // 출입문
        let door = layout.doorX
        shapes += [
            .rect(door, 48, 72, 112, r: 6, fill: .swatch(.woodDark)),
            .rect(door + 8, 56, 56, 104, r: 4, fill: .swatch(.wood)),
            .rect(door + 20, 68, 32, 30, r: 4, fill: .swatch(.sky)),
            .circle(door + 54, 114, 3.5, fill: .swatch(.butter)),
            .rect(door + 14, 30, 44, 14, r: 4, fill: .swatch(.plate), width: 1.3),
            .text("입구", door + 36, 37, size: 8, baseline: .central),
        ]
        shapes += pantry().transformed(offset: MapPoint(layout.pantryX - 908, 0))
        return [ArtLayer("wall", depth: -.infinity, shapes)]
    }

    /// 탕비 코너 (서버랙이 있던 오른쪽 벽): 냉장고, 정수기, 컵과 간식 선반
    static func pantry() -> [ArtShape] {
        var shapes: [ArtShape] = [
            .rect(948, 10, 78, 16, r: 5, fill: .swatch(.plate), width: 1.3),
            .text("탕비 코너", 987, 18, size: 8.5, baseline: .central),
            // 냉장고
            .rect(908, 32, 72, 128, r: 9, fill: .color(ArtColor(0xF4F7F8))),
            .line("M908,78 L980,78", width: 1.6),
            .rect(968, 46, 4, 22, r: 2, fill: .swatch(.metal), width: 1.1),
            .rect(968, 90, 4, 30, r: 2, fill: .swatch(.metal), width: 1.1),
            .circle(922, 52, 4, fill: .swatch(.peach), width: 1),
            .rect(930, 96, 14, 10, r: 2, fill: .swatch(.butter), width: 1),
            .circle(924, 116, 3.5, fill: .swatch(.mint), width: 1),
            // 정수기
            .rect(998, 92, 48, 68, r: 7, fill: .color(ArtColor(0xF4F7F8))),
            .rect(1006, 104, 32, 16, r: 4, fill: .swatch(.rackDark), outline: false),
            .rect(1012, 108, 5, 7, r: 1.5, fill: .swatch(.skyBlue), outline: false),
            .rect(1026, 108, 5, 7, r: 1.5, fill: .swatch(.alert), outline: false),
            .rect(1008, 136, 28, 4, r: 2, fill: .swatch(.metal), width: 1),
            .rect(1008, 40, 28, 52, r: 10, fill: .swatch(.drop), opacity: 0.85),
            .rect(1014, 48, 5, 30, r: 2.5, fill: .swatch(.white), outline: false, opacity: 0.6),
            .rect(1014, 86, 16, 8, r: 2, fill: .swatch(.metal), width: 1.2),
            // 컵과 간식 선반
            .rect(1060, 110, 50, 50, r: 6, fill: .swatch(.wood)),
            .rect(1060, 104, 50, 8, r: 3, fill: .swatch(.woodTop)),
            .rect(1066, 86, 10, 18, r: 2, fill: .swatch(.white), width: 1.2),
            .rect(1068, 80, 10, 18, r: 2, fill: .swatch(.white), width: 1.2),
            .path("M1082,104 L1084,88 L1104,88 L1106,104 Z", fill: .swatch(.butter), width: 1.3),
            .circle(1090, 86, 4, fill: .swatch(.peach), width: 1),
            .circle(1099, 85, 4, fill: .swatch(.pink), width: 1),
        ]
        shapes += plant(at: MapPoint(1100, 158), scale: 0.5)
        return shapes
    }

    // MARK: - 책상

    /// 자리별 의자 색
    static let chairColors: [UInt32] = [0x7FC9B3, 0xF0A58B, 0xB6A6E4, 0xE9CB6C]
    static let plateFontSize = 9.5
    static let platePadding = 6.0
    /// 명패를 앞판 가운데보다 올리는 양
    static let plateLift = 1.0
    /// 명패 안 글자를 명패 가운데보다 내리는 양 (한글 글꼴은 central 기준선에서 위로 떠 보입니다)
    static let plateTextDrop = 0.5

    /// 글자 폭 어림값 (한글·기호는 정사각형, 영문·숫자는 그 절반 남짓). 렌더러마다 글꼴이 달라 넉넉하게 잡습니다.
    static func estimatedWidth(_ text: String, size: Double) -> Double {
        text.unicodeScalars.reduce(0) { sum, scalar in
            if scalar == " " { return sum + size * 0.3 }
            return sum + (scalar.isASCII ? size * 0.52 : size * 1.0)
        }
    }

    /// 폭에 맞지 않으면 뒤를 잘라 "…"을 붙입니다. 돌려주는 폭은 어림값입니다.
    static func fitted(_ text: String, size: Double, maxWidth: Double) -> (String, Double) {
        let full = estimatedWidth(text, size: size)
        if full <= maxWidth { return (text, full) }
        var cut = text
        while !cut.isEmpty, estimatedWidth(cut + "…", size: size) > maxWidth { cut.removeLast() }
        let result = cut + "…"
        return (result, estimatedWidth(result, size: size))
    }

    /// 책상 하나: 의자(직원 뒤, 깊이 y-1)와 책상(직원 앞, 깊이 y+3). (x, y)는 앉은 직원의 발 위치입니다.
    static func desk(_ name: String, x: Double, y: Double, chair: Int, plate: String?, plant: Bool) -> [ArtLayer] {
        var desk: [ArtShape] = [
            .rect(x - 41, y - 33, 82, 11, r: 4, fill: .swatch(.woodTop)),
            .rect(x - 41, y - 24, 82, 27, r: 5, fill: .swatch(.wood)),
            .rect(x - 40, y - 46, 26, 14, r: 3, fill: .swatch(.metal)),
            .circle(x - 27, y - 39, 2, fill: .swatch(.metalDot), outline: false),
        ]
        if let plate {
            let (text, textWidth) = fitted(plate, size: plateFontSize, maxWidth: 78 - 2 * platePadding)
            let width = max(textWidth, 28) + 2 * platePadding
            // 책상 앞판에서 보이는 부분(상판 아래 y-22 ~ y+3)의 세로 가운데보다 조금 위에 답니다
            // (상판 테두리 때문에 기하학적 가운데는 화면에서 아래로 치우쳐 보입니다)
            let plateCenter = y - 9.5 - plateLift
            desk += [
                .rect(x - width / 2, plateCenter - 7.5, width, 15, r: 4, fill: .swatch(.plate), width: 1.2),
                .text(text, x, plateCenter + plateTextDrop, size: plateFontSize, bold: true, baseline: .central),
            ]
        }
        if plant {
            desk += self.plant(at: MapPoint(x + 29, y - 33), scale: 0.4)
        }
        return [
            ArtLayer("chair-\(name)", depth: y - 1, [.rect(x - 17, y - 60, 34, 36, r: 11, fill: .color(ArtColor(chairColors[chair % 4])))]),
            ArtLayer("desk-\(name)", depth: y + 3, desk),
        ]
    }

    // MARK: - 행

    /// 행 하나: 책상(사람 수만큼, 0번 = 메인), 메인 책상 아래 폴더 이름 표지, 숨긴 사람이 있으면 행 끝 "+N"
    static func row(_ row: OfficeLayout.Row, team: Team?, plates: [Seat: String]) -> [ArtLayer] {
        var layers: [ArtLayer] = []
        let y = row.deskY
        for desk in 0..<row.desks {
            layers += self.desk(
                "\(row.team.raw)-\(desk)", x: OfficeLayout.deskX(desk), y: y, chair: desk + (team?.colorIndex ?? 0),
                plate: plates[Seat(desk: desk)], plant: desk == 0)
        }
        if let team {
            layers.append(ArtLayer("row-sign-\(row.team.raw)", depth: -.infinity, sign(team.name, at: MapPoint(OfficeLayout.deskX(0), y), color: team.colorIndex)))
        }
        if row.hidden > 0 {
            layers.append(ArtLayer("row-more-\(row.team.raw)", depth: -.infinity, more(row.hidden, at: MapPoint(row.endX + 26, y - 18))))
        }
        return layers
    }

    /// 행 표지 (메인 책상 바로 아래): 메인 색 점 + 폴더 이름
    static func sign(_ label: String, at desk: MapPoint, color: Int) -> [ArtShape] {
        let (text, textWidth) = fitted(label, size: 9, maxWidth: 110)
        let width = textWidth + 26
        let x = desk.x - OfficeLayout.deskWidth / 2
        return [
            .rect(x, desk.y + 9, width, 16, r: 8, fill: .swatch(.plate), width: 1.2),
            .circle(x + 9, desk.y + 17, 3.5, fill: .swatch(Swatch.teamColors[color % 4]), width: 1),
            .text(text, x + 16, desk.y + 17.5, size: 9, color: .swatch(.ink), anchor: .start, baseline: .central),
        ]
    }

    /// 행 끝 "+N" (화면에 다 못 보여 준 사람 수)
    static func more(_ count: Int, at center: MapPoint) -> [ArtShape] {
        let label = "+\(count)"
        let width = max(30, estimatedWidth(label, size: 11) + 14)
        return [
            .rect(center.x - width / 2, center.y - 11, width, 22, r: 11, fill: .swatch(.plate), width: 1.4),
            .text(label, center.x, center.y + 0.5, size: 11, bold: true, color: .swatch(.ink), baseline: .central),
        ]
    }

    // MARK: - 휴게 공간 (위쪽 왼쪽, 뒷벽 앞)

    static let massageSeat = OfficeLayout.massageSeat

    static func lounge() -> [ArtLayer] {
        var layers: [ArtLayer] = []
        // 2인용 소파 (앉는 자리 y 214): 등받이는 앉은 직원 뒤, 앉는 판과 팔걸이는 앞
        for (index, sofa) in OfficeLayout.sofas.enumerated() {
            let x = sofa.x
            layers.append(ArtLayer("sofa-back-\(index)", depth: 184, [
                .rect(x + 6, 172, 84, 38, r: 16, fill: .color(ArtColor(0x9C8FCF))),
            ]))
            layers.append(ArtLayer("sofa-front-\(index)", depth: 217, [
                .rect(x + 10, 200, 76, 26, r: 10, fill: .color(ArtColor(0xB3A7E2))),
                .rect(x + 47, 202, 2, 20, r: 1, fill: .color(ArtColor(0x9C8FCF)), outline: false),
                .rect(x - 2, 184, 18, 44, r: 9, fill: .color(ArtColor(0x9C8FCF))),
                .rect(x + 80, 184, 18, 44, r: 9, fill: .color(ArtColor(0x9C8FCF))),
            ]))
        }
        // 큰 화분 둘 (두 소파 사이, 소파 구역과 안마 구역 사이)
        for (index, origin) in OfficeLayout.bigPlants.enumerated() {
            layers.append(ArtLayer("big-plant-\(index)", depth: origin.y, bigPlant(at: origin)))
        }
        // 안마 의자: 등판(직원 뒤) → 롤러(움직임, liveLayers) → 직원 → 앉는 판·팔걸이·발판(앞)
        for (index, s) in OfficeLayout.massageSeats.enumerated() {
            layers.append(ArtLayer("massage-back-\(index)", depth: s.y - 1, [
                .rect(s.x - 26, s.y - 98, 52, 80, r: 16, fill: .color(ArtColor(0x6F86A8))),
                .rect(s.x - 20, s.y - 90, 40, 64, r: 12, fill: .color(ArtColor(0x8EA6C8)), outline: false),
                .rect(s.x - 18, s.y - 108, 36, 18, r: 9, fill: .color(ArtColor(0x8EA6C8))),
            ]))
            layers.append(ArtLayer("massage-front-\(index)", depth: s.y + 1, [
                .rect(s.x - 24, s.y - 22, 48, 18, r: 8, fill: .color(ArtColor(0x8EA6C8))),
                .rect(s.x - 34, s.y - 44, 14, 40, r: 7, fill: .color(ArtColor(0x6F86A8))),
                .rect(s.x + 20, s.y - 44, 14, 40, r: 7, fill: .color(ArtColor(0x6F86A8))),
                .rect(s.x + 23, s.y - 40, 8, 6, r: 2, fill: .swatch(.mint), outline: false),
                .rect(s.x - 14, s.y - 4, 28, 12, r: 5, fill: .color(ArtColor(0x6F86A8))),
            ]))
        }
        return layers
    }

    /// 안마 의자 등판 롤러 두 개. 누가 앉아 있으면 위아래로 오르내리고, 비어 있으면 위쪽에 멈춰 있습니다.
    static func massageRoller(at s: MapPoint = massageSeat, time: Double?) -> [ArtShape] {
        let phase = time.map { (1 - cos($0 * 2 * Double.pi / 2.6)) / 2 } ?? 0
        let y = s.y - 82 + phase * 46
        return [
            .rect(s.x - 15, s.y - 86, 4, 56, r: 2, fill: .color(ArtColor(0x6F86A8)), outline: false, opacity: 0.6),
            .rect(s.x + 11, s.y - 86, 4, 56, r: 2, fill: .color(ArtColor(0x6F86A8)), outline: false, opacity: 0.6),
            .circle(s.x - 13, y, 5, fill: .swatch(.lavender), width: 1.3),
            .circle(s.x + 13, y, 5, fill: .swatch(.lavender), width: 1.3),
        ]
    }

    /// 큰 화분 (발 위치 기준): 키 큰 잎 다섯 장과 큰 화분
    static func bigPlant(at origin: MapPoint) -> [ArtShape] {
        [
            .path("M0,-26 C-24,-30 -34,-58 -22,-72 C-12,-56 -4,-42 0,-26 Z", fill: .color(ArtColor(0x86C9A9))),
            .path("M0,-26 C22,-32 32,-60 20,-74 C10,-58 3,-42 0,-26 Z", fill: .color(ArtColor(0x86C9A9))),
            .path("M0,-26 C-14,-40 -16,-70 -6,-88 C2,-70 2,-46 0,-26 Z", fill: .color(ArtColor(0x7CBF9E))),
            .path("M0,-26 C12,-42 16,-72 8,-90 C0,-72 -2,-46 0,-26 Z", fill: .swatch(.mint)),
            .path("M0,-26 C-30,-24 -40,-44 -34,-52 C-22,-44 -10,-34 0,-26 Z", fill: .swatch(.mint)),
            .path("M-17,-28 H17 L13,0 H-13 Z", fill: .swatch(.pot)),
            .rect(-19, -32, 38, 7, r: 3, fill: .swatch(.pot)),
        ].transformed(scale: 1, offset: origin)
    }

    /// 긴 명령을 기다리는 직원의 모니터: 진행 막대가 차오르고 작은 불빛이 깜빡입니다. (x, y)는 직원 발 위치입니다.
    static func monitorProgress(at position: MapPoint, time: Double, seed: String) -> [ArtShape] {
        let x = position.x
        let y = position.y
        let offset = Double(StableHashLite.value(seed) % 100) / 100 * 3
        let progress = ((time + offset) / 3).truncatingRemainder(dividingBy: 1)
        let blink = Int((time + offset) * 2) % 2 == 0
        return [
            .rect(x - 38, y - 44, 22, 10, r: 2, fill: .swatch(.screenGlow), outline: false),
            .rect(x - 36, y - 40, 18, 3, r: 1.5, fill: .swatch(.white), outline: false, opacity: 0.7),
            .rect(x - 36, y - 40, max(1.5, 18 * progress), 3, r: 1.5, fill: .swatch(.drop), outline: false),
            .circle(x - 19, y - 36, 1.4, fill: .swatch(blink ? .butter : .metalDot), outline: false),
        ]
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
