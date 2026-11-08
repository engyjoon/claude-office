import Foundation
import OfficeCore

/// 사무실 바닥·벽·가구·팀장실·파트 칸 그림 (미리보기 docs/preview의 officeScene을 바탕으로 M4.5b 배치에 맞춘 것)
public enum OfficeArt {
    /// 바닥에 깔리는 것과 움직이지 않는 가구. 깊이 순서대로 직원과 섞어 그리면 됩니다.
    /// - Parameters:
    ///   - teams: 띠마다 방 이름·색을 찾을 방 목록
    ///   - nameplates: 책상 명패 (방 → 자리 → 이름)
    ///   - podSigns: 파트 칸 표지 (방 → 칸 → 글자)
    ///   - extent: 화면에 보이는 영역(지도 좌표). 창 비율이 사무실과 달라 남는 곳까지 벽과 바닥을 이어 그립니다.
    ///     nil이면 사무실 크기(0, 0, width, height)만 그립니다.
    public static func layers(
        layout: OfficeLayout, teams: [Team], nameplates: [TeamID: [Seat: String]] = [:], podSigns: [TeamID: [Int: String]] = [:],
        extent: MapRect? = nil
    ) -> [ArtLayer] {
        var layers = [ArtLayer("background", depth: -.infinity, background(layout: layout, teams: teams, podSigns: podSigns, extent: extent))]
        layers += wallFurniture()
        layers += researchDesk()
        let bands = layout.bands.isEmpty ? [layout.firstBand] : layout.bands
        for band in bands {
            let team = teams.first { $0.id == band.team }
            let plates = nameplates[band.team] ?? [:]
            layers += office(band, team: team, plate: plates[.office])
            for cell in 0..<band.cells {
                layers += pod(band, cell: cell, team: team, plates: plates, sign: podSigns[band.team]?[cell])
            }
        }
        layers += lounge()
        return layers
    }

    /// 시간에 따라 움직이는 가구: 안마 의자 등판 롤러, 긴 명령을 기다리는 직원의 모니터 진행 표시.
    /// 매 프레임 다시 계산합니다 (렌더러는 바뀐 경우에만 다시 그리면 됩니다).
    public static func liveLayers(stage: Stage) -> [ArtLayer] {
        let time = stage.time
        var layers: [ArtLayer] = []
        let massaged = stage.actors.values.contains { actor in
            actor.place?.key == "massageChair:0" && !actor.isWalking && actor.position.distance(to: massageSeat) < 1
        }
        layers.append(ArtLayer("massage-roller", depth: massageSeat.y - 0.5, massageRoller(time: massaged ? time : nil)))
        for actor in stage.sortedActors where actor.pose == .watching && actor.seated && !actor.isWalking {
            layers.append(ArtLayer("monitor-\(actor.id.raw)", depth: actor.position.y + 3.5, monitorProgress(at: actor.position, time: time, seed: actor.id.raw)))
        }
        return layers
    }

    // MARK: - 바닥과 벽

    static func background(layout: OfficeLayout, teams: [Team] = [], podSigns: [TeamID: [Int: String]] = [:], extent: MapRect? = nil) -> [ArtShape] {
        let area = extent ?? MapRect(0, 0, OfficeLayout.width, layout.height)
        let left = min(area.x, 0)
        let right = max(area.maxX, OfficeLayout.width)
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
        // 파트 칸 러그: 방 색. 쓰는 파트가 없는 빈 칸은 옅게
        let bands = layout.bands.isEmpty ? [layout.firstBand] : layout.bands
        for band in bands {
            let color = teams.first { $0.id == band.team }?.colorIndex ?? 0
            for cell in 0..<band.cells {
                let center = OfficeLayout.cellCenter(band, cell: cell)
                let empty = podSigns[band.team]?[cell] == "빈 칸"
                shapes.append(.rect(center.x - 190, center.y - 84, 380, 114, r: 28, fill: .swatch(Swatch.teamRugs[color % 4]), outline: false, opacity: empty ? 0.28 : 0.55))
            }
            // 팀장실 바닥 (카펫)
            let office = band.office
            shapes.append(.rect(10, max(office.y, OfficeLayout.walkTop) + 6, 186, office.maxY - max(office.y, OfficeLayout.walkTop) - 18, r: 18,
                fill: .swatch(Swatch.teamRugs[color % 4]), outline: false, opacity: 0.4))
        }
        // 휴게 공간 러그와 현관 매트
        shapes.append(.rect(6, 452, 198, 172, r: 30, fill: .swatch(.rugC), outline: false, opacity: 0.85))
        shapes.append(.rect(796, 162, 64, 10, r: 5, fill: .swatch(.rugC)))
        return shapes
    }

    static func wallFurniture() -> [ArtLayer] {
        var shapes: [ArtShape] = []
        // 팀장실 벽: 액자와 시계
        shapes += [
            .rect(28, 40, 92, 66, r: 5, fill: .swatch(.woodDark)),
            .rect(35, 47, 78, 52, r: 3, fill: .swatch(.sky2), outline: false),
            .path("M35,99 L58,72 L74,88 L88,76 L113,99 Z", fill: .swatch(.mint), width: 1.4),
            .circle(98, 60, 6, fill: .swatch(.butter), width: 1.2),
            .circle(166, 70, 18, fill: .swatch(.white)),
            .line("M166,70 L166,59 M166,70 L174,74"),
            .circle(166, 70, 2, fill: .swatch(.ink), outline: false),
        ]
        // 책장 (팀장실 칸막이 오른쪽)
        let shelfX = 222.0
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
        // 창문 두 개 (아래에 리서치 데스크)
        for x in [384.0, 494.0] {
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
        shapes += plant(at: MapPoint(487, 113), scale: 0.55)
        // 화이트보드
        let board = 630.0 - 512
        shapes += [
            .rect(512 + board, 36, 128, 80, r: 6, fill: .swatch(.board)),
            .line("M528,54 h8 v8 h-8 z M542,58 h56 M528,72 h8 v8 h-8 z M542,76 h44 M528,90 h8 v8 h-8 z M542,94 h66", width: 1.5)
                .transformed(offset: MapPoint(board, 0)),
            .line("M529,57 l3,3 l5,-6 M529,75 l3,3 l5,-6", width: 2, color: .swatch(.check)).transformed(offset: MapPoint(board, 0)),
            .rect(532 + board, 116, 88, 6, r: 3, fill: .swatch(.wallTrim)),
            .rect(600 + board, 111, 12, 5, r: 2, fill: .swatch(.alert), outline: false),
        ]
        // 출입문
        let door = 792.0
        shapes += [
            .rect(door, 48, 72, 112, r: 6, fill: .swatch(.woodDark)),
            .rect(door + 8, 56, 56, 104, r: 4, fill: .swatch(.wood)),
            .rect(door + 20, 68, 32, 30, r: 4, fill: .swatch(.sky)),
            .circle(door + 54, 114, 3.5, fill: .swatch(.butter)),
            .rect(door + 14, 30, 44, 14, r: 4, fill: .swatch(.plate), width: 1.3),
            .text("입구", door + 36, 37, size: 8, baseline: .central),
        ]
        shapes += pantry()
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

    /// 창가 리서치 데스크: 서서 쓰는 긴 테이블과 노트북. 직원은 데스크 뒤(창 쪽)에 서서 화면 쪽을 봅니다.
    static func researchDesk() -> [ArtLayer] {
        let desk = OfficeLayout.researchDesk
        var shapes: [ArtShape] = []
        for x in [420.0, 468.0, 516.0, 564.0] {
            shapes += [
                .rect(x - 11, 168, 22, 15, r: 2.5, fill: .swatch(.metal)),
                .circle(x, 175.5, 2, fill: .swatch(.metalDot), outline: false),
            ]
        }
        shapes += [
            .rect(desk.x, 180, desk.width, 10, r: 4, fill: .swatch(.woodTop)),
            .rect(desk.x + 4, 188, desk.width - 8, desk.maxY - 188, r: 5, fill: .swatch(.wood)),
            .rect(desk.x + desk.width / 2 - 34, 200, 68, 14, r: 4, fill: .swatch(.plate), width: 1.2),
            .text("리서치", desk.x + desk.width / 2, 207, size: 8.5, bold: true, baseline: .central),
        ]
        return [ArtLayer("research-desk", depth: desk.maxY, shapes)]
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

    /// 칸·방 표지 (책상 줄 아래 가운데)
    static func sign(_ label: String, at center: MapPoint, color: Int?, faded: Bool = false) -> [ArtShape] {
        let width = TextMetrics.width(label, size: 10) + (color == nil ? 22 : 32)
        var shapes: [ArtShape] = [.rect(center.x - width / 2, center.y + 35, width, 20, r: 10, fill: .swatch(.plate), width: 1.4, opacity: faded ? 0.7 : 1)]
        if let color {
            shapes.append(.circle(center.x - width / 2 + 11, center.y + 45, 4, fill: .swatch(Swatch.teamColors[color % 4]), width: 1))
        }
        shapes.append(.text(label, center.x + (color == nil ? 0 : 6), center.y + 45, size: 10, color: .swatch(faded ? .plateInk : .ink), baseline: .central))
        return shapes
    }

    // MARK: - 팀장실

    /// 팀장실: 낮은 유리 칸막이(오른쪽에 출입구 틈), 칸막이 화분, 책상 하나, 방 이름 표지
    static func office(_ band: OfficeLayout.Band, team: Team?, plate: String?) -> [ArtLayer] {
        let y = band.deskY(row: 0)
        var layers = desk("office-\(band.team.raw)", x: OfficeLayout.officeDeskX, y: y, chair: 0, plate: plate, plant: true)
        if let team {
            layers.append(ArtLayer("office-sign-\(band.team.raw)", depth: -.infinity, sign(team.name, at: MapPoint(OfficeLayout.officeDeskX, y - 6), color: team.colorIndex)))
        }
        let office = band.office
        let door = band.officeDoor
        let wallX = OfficeLayout.sideWidth
        let glassHeight = 30.0
        // 오른쪽 칸막이 (세로 유리판 두 장, 사이가 출입구)
        func vertical(_ from: Double, _ to: Double) -> [ArtShape] {
            [
                .rect(wallX - 4, from - glassHeight, 8, to - from + glassHeight, r: 3, fill: .swatch(.sky), width: 1.4, opacity: 0.55),
                .rect(wallX - 5, to - glassHeight - 2, 10, glassHeight + 4, r: 3, fill: .swatch(.metal), width: 1.3),
            ]
        }
        let top = max(office.y, OfficeLayout.wallBottom + 2)
        layers.append(ArtLayer("office-glass-upper-\(band.team.raw)", depth: door.top, vertical(top + glassHeight, door.top)))
        layers.append(ArtLayer("office-glass-lower-\(band.team.raw)", depth: office.maxY - 1, vertical(door.bottom + glassHeight, office.maxY)))
        // 출입구 표지
        layers.append(ArtLayer("office-door-\(band.team.raw)", depth: door.top + 0.5, [
            .rect(wallX - 24, door.top - glassHeight - 20, 48, 15, r: 4, fill: .swatch(.plate), width: 1.2),
            .text("팀장실", wallX, door.top - glassHeight - 12.5, size: 8, bold: true, baseline: .central),
        ]))
        // 아래쪽 칸막이 (가로 유리판) + 화분
        func horizontal(_ lineY: Double, name: String) -> ArtLayer {
            var shapes: [ArtShape] = [
                .rect(0, lineY - glassHeight, wallX + 4, glassHeight, r: 3, fill: .swatch(.sky), width: 1.4, opacity: 0.45),
                .rect(0, lineY - glassHeight - 3, wallX + 4, 5, r: 2.5, fill: .swatch(.metal), width: 1.2),
                .line("M18,\(lineY - glassHeight + 8) l12,-6 M150,\(lineY - glassHeight + 12) l14,-7", width: 1.4, color: .swatch(.white), opacity: 0.8),
            ]
            shapes += plant(at: MapPoint(16, lineY + 2), scale: 0.62)
            shapes += plant(at: MapPoint(wallX - 14, lineY + 2), scale: 0.62)
            return ArtLayer(name, depth: lineY + 2, shapes)
        }
        layers.append(horizontal(office.maxY, name: "office-glass-bottom-\(band.team.raw)"))
        return layers
    }

    // MARK: - 파트 칸

    /// 파트 칸: 책상 4개(0번 = 세션 팀원 ★ 자리)와 칸 표지
    static func pod(_ band: OfficeLayout.Band, cell: Int, team: Team?, plates: [Seat: String], sign label: String?) -> [ArtLayer] {
        let center = OfficeLayout.cellCenter(band, cell: cell)
        var layers: [ArtLayer] = []
        let partPod = cell > 0 && label != nil && label != "빈 칸"
        for (index, offset) in OfficeLayout.podDeskOffsets.enumerated() {
            let seat = Seat(part: cell, desk: index)
            layers += desk(
                "\(band.team.raw)-\(cell)-\(index)", x: center.x + offset, y: center.y, chair: index + cell,
                plate: plates[seat], plant: partPod && index == 0)
        }
        if let label {
            let empty = label == "빈 칸"
            layers.append(ArtLayer("pod-sign-\(band.team.raw)-\(cell)", depth: -.infinity,
                sign(label, at: center, color: empty ? nil : team?.colorIndex, faded: empty)))
        }
        return layers
    }

    // MARK: - 휴게 공간 (팀장실 아래 왼쪽 열)

    static let massageSeat = OfficeLayout.massageSeat

    static func lounge() -> [ArtLayer] {
        var layers: [ArtLayer] = []
        // 소파 등받이는 앉은 직원 뒤, 앉는 판과 팔걸이는 앞
        layers.append(ArtLayer("sofa-back", depth: 490, [
            .rect(20, 478, 116, 38, r: 16, fill: .color(ArtColor(0x9C8FCF))),
        ]))
        layers.append(ArtLayer("sofa-front", depth: 523, [
            .rect(24, 506, 108, 26, r: 10, fill: .color(ArtColor(0xB3A7E2))),
            .rect(12, 490, 18, 44, r: 9, fill: .color(ArtColor(0x9C8FCF))),
            .rect(126, 490, 18, 44, r: 9, fill: .color(ArtColor(0x9C8FCF))),
        ]))
        // 커피 카운터 (왼쪽 아래)
        layers.append(ArtLayer("coffee", depth: 628, [
            .rect(10, 596, 54, 32, r: 6, fill: .swatch(.wood)),
            .rect(10, 592, 54, 7, r: 3, fill: .swatch(.woodTop)),
            .rect(18, 558, 32, 36, r: 6, fill: .swatch(.rack)),
            .rect(25, 565, 18, 8, r: 2, fill: .swatch(.mint), outline: false),
            .rect(28, 580, 12, 10, r: 2, fill: .swatch(.white)),
            .rect(53, 582, 7, 10, r: 2, fill: .swatch(.white), width: 1.1),
        ]))
        layers.append(ArtLayer("lounge-plant", depth: 630, plant(at: MapPoint(196, 630), scale: 0.6)))
        // 안마 의자 (오른쪽 위): 등판(직원 뒤) → 롤러(움직임, liveLayers) → 직원 → 앉는 판·팔걸이·발판(앞)
        let s = massageSeat
        layers.append(ArtLayer("massage-back", depth: s.y - 1, [
            .rect(s.x - 26, s.y - 98, 52, 80, r: 16, fill: .color(ArtColor(0x6F86A8))),
            .rect(s.x - 20, s.y - 90, 40, 64, r: 12, fill: .color(ArtColor(0x8EA6C8)), outline: false),
            .rect(s.x - 18, s.y - 108, 36, 18, r: 9, fill: .color(ArtColor(0x8EA6C8))),
        ]))
        layers.append(ArtLayer("massage-front", depth: s.y + 1, [
            .rect(s.x - 24, s.y - 22, 48, 18, r: 8, fill: .color(ArtColor(0x8EA6C8))),
            .rect(s.x - 34, s.y - 44, 14, 40, r: 7, fill: .color(ArtColor(0x6F86A8))),
            .rect(s.x + 20, s.y - 44, 14, 40, r: 7, fill: .color(ArtColor(0x6F86A8))),
            .rect(s.x + 23, s.y - 40, 8, 6, r: 2, fill: .swatch(.mint), outline: false),
            .rect(s.x - 14, s.y - 4, 28, 12, r: 5, fill: .color(ArtColor(0x6F86A8))),
        ]))
        return layers
    }

    /// 안마 의자 등판 롤러 두 개. 누가 앉아 있으면 위아래로 오르내리고, 비어 있으면 위쪽에 멈춰 있습니다.
    static func massageRoller(time: Double?) -> [ArtShape] {
        let s = massageSeat
        let phase = time.map { (1 - cos($0 * 2 * Double.pi / 2.6)) / 2 } ?? 0
        let y = s.y - 82 + phase * 46
        return [
            .rect(s.x - 15, s.y - 86, 4, 56, r: 2, fill: .color(ArtColor(0x6F86A8)), outline: false, opacity: 0.6),
            .rect(s.x + 11, s.y - 86, 4, 56, r: 2, fill: .color(ArtColor(0x6F86A8)), outline: false, opacity: 0.6),
            .circle(s.x - 13, y, 5, fill: .swatch(.lavender), width: 1.3),
            .circle(s.x + 13, y, 5, fill: .swatch(.lavender), width: 1.3),
        ]
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
