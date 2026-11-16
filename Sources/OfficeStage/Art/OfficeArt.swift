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
    ///   - lounge: 휴게 공간(소파·안마 의자와 그 러그)을 그릴지. 미니 사무실은 그리지 않습니다 (M5(4) v2).
    ///   - lighting: 밤이면 벽·바닥·가구를 밤 팔레트로 칠하고, 창밖을 밤하늘로, 휴게 공간에 스탠드를 켭니다 (M6(6)).
    ///     사람 있는 책상의 불빛은 자리에 따라 바뀌므로 따로 `deskLight(at:)`로 그립니다.
    ///   - contrast: 시스템 "대비 증가" (M6(7)). 명패·행 표지·"+N" 테두리를 굵게 합니다.
    ///   - signTitles: 행 표지 둘째 줄에 덧붙일 세션 제목 (개선 8, `Stage.signTitles`). 표시 수준이 "상세"일 때만 넘깁니다.
    public static func layers(
        layout: OfficeLayout, teams: [Team], nameplates: [TeamID: [Seat: String]] = [:], extent: MapRect? = nil, lounge: Bool = true,
        lighting: Lighting = .day, contrast: Bool = false, signTitles: [TeamID: String] = [:]
    ) -> [ArtLayer] {
        var layers = [ArtLayer("background", depth: -.infinity, background(layout: layout, teams: teams, extent: extent, lounge: lounge))]
        var signs: [ArtLayer] = []
        for row in layout.rows {
            let team = teams.first { $0.id == row.team }
            layers += self.row(row, team: team, plates: nameplates[row.team] ?? [:])
            if let team {
                signs.append(ArtLayer(
                    "row-sign-\(row.team.raw)", depth: -.infinity,
                    sign(
                        team.name, title: signTitles[team.id], at: MapPoint(OfficeLayout.deskX(0), row.deskY), color: team.colorIndex,
                        lighting: lighting, contrast: contrast)))
            }
        }
        if lounge { layers += self.lounge() }
        if contrast { layers = layers.map(boostPlates) }
        layers = layers.map { $0.lit(lighting) }
        // 행 표지는 스스로 조명·대비를 맞춥니다 (밤에도 행 색을 밝게 둠, M6(8)). 깊이 −∞ 층들 가운데 나중에 두어 바닥·러그 위에 그립니다.
        layers += signs
        // 벽 가구는 스스로 밤 색을 칠합니다 (창밖 그림이 낮·밤으로 다름). 바탕 바로 뒤에 둡니다.
        layers.insert(contentsOf: wallFurniture(layout, lighting: lighting, lounge: lounge), at: 1)
        if lighting == .night, lounge {
            // 소파 옆 스탠드와 그 불빛 (휴게 공간은 늘 켜 둠). 불빛은 바닥·러그 위, 가구 아래.
            layers.insert(ArtLayer("lounge-light", depth: -.infinity, loungeGlow()), at: 1)
            layers.append(ArtLayer("floor-lamp", depth: floorLampFoot.y - 2, floorLamp(at: floorLampFoot)))
        }
        return layers
    }

    /// 시간에 따라 움직이는 가구: 안마 의자 등판 롤러, 긴 명령을 기다리는 직원의 모니터 진행 표시.
    /// 매 프레임 다시 계산합니다 (렌더러는 바뀐 경우에만 다시 그리면 됩니다).
    /// - Parameter time: 그림에 쓸 무대 시각 (기본은 지금). 앱은 1/15초 단위로 맞춰 넘겨서 같은 그림(구운 텍스처)이 주기마다 다시 쓰이게 합니다 (M6(1)).
    public static func liveLayers(stage: Stage, time: Double? = nil, lighting: Lighting = .day) -> [ArtLayer] {
        liveLayers(stage: stage, time: time).map { $0.lit(lighting) }
    }

    static func liveLayers(stage: Stage, time: Double?) -> [ArtLayer] {
        let time = time ?? stage.time
        var layers: [ArtLayer] = []
        for (index, seat) in OfficeLayout.massageSeats.enumerated() where !stage.config.commonAreasAtDesk {
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

    static func background(layout: OfficeLayout, teams: [Team] = [], extent: MapRect? = nil, lounge: Bool = true) -> [ArtShape] {
        let area = extent ?? MapRect(0, 0, layout.width, layout.height)
        let left = min(area.x, 0)
        let right = max(area.maxX, layout.width)
        let top = min(area.y, 0)
        let bottom = max(area.maxY, layout.height)
        let width = right - left
        // 벽 · 허리 판벽(벽 아래 44pt, 세로 홈 64pt마다) · 걸레받이(벽 아래 10pt) · 바닥
        let wall = OfficeLayout.wallBottom
        var shapes: [ArtShape] = [
            .rect(left, top, width, wall - top, fill: .swatch(.wall), outline: false),
            .rect(left, wall - 44, width, 34, fill: .swatch(.wallTrim), outline: false),
            .rect(left, wall - 46.5, width, 2.5, fill: .swatch(.baseboard), outline: false),
            .rect(left, wall - 10, width, 10, fill: .swatch(.baseboard), outline: false),
            .rect(left, wall, width, bottom - wall, fill: .swatch(.floor), outline: false),
        ]
        var groove = (left / 64).rounded(.down) * 64 + 32
        while groove < right {
            shapes.append(.rect(groove, wall - 39, 1.5, 24, r: 0.75, fill: .swatch(.wall), outline: false))
            groove += 64
        }
        // 마루: 가로줄은 36pt마다, 세로 이음매는 210pt마다 한 줄씩 엇갈립니다 (사무실 밖으로도 같은 무늬).
        // 널 몇 장은 조금 짙게 칠하고 짧은 나뭇결을 넣습니다 (널 번호로 정해 늘 같은 자리).
        var y = wall + 36
        var row = 0
        let limit = extent == nil ? bottom : bottom + 36  // 화면을 채울 때는 맨 아래 반쪽 줄까지
        while y < limit {
            shapes.append(.rect(left, y, width, 2, fill: .swatch(.floorLine), outline: false))
            let base = row % 2 == 1 ? 60.0 : 150.0
            var plank = ((left - base) / 210).rounded(.down)
            while base + plank * 210 < right {
                let x = base + plank * 210
                if x >= left { shapes.append(.rect(x, y - 34, 2, 34, fill: .swatch(.floorLine), outline: false)) }
                let seed = StableHashLite.value("plank \(row) \(Int(plank))")
                if seed % 4 == 0 {
                    shapes.append(.rect(x + 2, y - 34, 208, 34, fill: .swatch(.floorLine), outline: false, opacity: 0.36))
                }
                let grainX = x + 16 + Double(seed % 140)
                let grainY = y - 26 + Double((seed / 7) % 16)
                shapes.append(.rect(grainX, grainY, 14 + Double(seed % 15), 1.3, r: 0.65, fill: .swatch(.floorLine), outline: false))
                if seed % 3 == 0 {
                    shapes.append(.rect(grainX + 22, grainY + 5, 9, 1.3, r: 0.65, fill: .swatch(.floorLine), outline: false))
                }
                plank += 1
            }
            y += 36
            row += 1
        }
        // 벽 바로 아래 바닥에 떨어지는 옅은 그늘
        shapes.append(.rect(left, wall, width, 5, fill: .swatch(.shadow), outline: false, opacity: 0.55))
        // 행 러그: 메인 색 (책상 수만큼) + 안쪽 테두리 한 줄
        for row in layout.rows {
            let color = teams.first { $0.id == row.team }?.colorIndex ?? 0
            let swatch = Swatch.teamRugs[color % 4]
            let from = OfficeLayout.deskX(0) - 52
            let to = row.endX + 11
            shapes.append(.rect(from, row.deskY - 84, to - from, 112, r: 26, fill: .swatch(swatch), outline: false, opacity: 0.5))
            shapes.append(ArtShape(.rect(MapRect(from + 6, row.deskY - 78, to - from - 12, 100), radius: 20), stroke: .swatch(swatch), lineWidth: 1.6))
        }
        // 휴게 공간 러그(소파 구역, 양 끝에 술), 안마 구역 러그, 현관 매트
        if lounge {
            let sofas = OfficeLayout.sofaArea
            let trim = Paint.color(ArtColor(0xC3B8E6))
            var fringe = ""
            var fy = sofas.y + 27
            while fy <= sofas.maxY - 27 {
                fringe += "M\(sofas.x - 4.5),\(fy) H\(sofas.x + 1) M\(sofas.maxX - 1),\(fy) H\(sofas.maxX + 4.5) "
                fy += 6
            }
            shapes.append(.line(fringe, width: 1.5, color: trim))
            shapes.append(.rect(sofas.x, sofas.y, sofas.width, sofas.height, r: 26, fill: .swatch(.rugC), outline: false, opacity: 0.8))
            shapes.append(ArtShape(.rect(MapRect(sofas.x + 6, sofas.y + 6, sofas.width - 12, sofas.height - 12), radius: 20), stroke: trim, lineWidth: 1.6))
            let m = OfficeLayout.massageArea
            shapes.append(.rect(m.x, m.y + 4, m.width, m.height - 6, r: 22, fill: .color(ArtColor(0xD4E2F2)), outline: false, opacity: 0.85))
            shapes.append(ArtShape(.rect(MapRect(m.x + 6, m.y + 10, m.width - 12, m.height - 18), radius: 16), stroke: .color(ArtColor(0xB6CBE6)), lineWidth: 1.6))
        }
        let mat = MapRect(layout.doorX + 5, wall + 2.5, OfficeLayout.doorWidth - 10, 11)
        shapes.append(.rect(mat.x, mat.y, mat.width, mat.height, r: 4.5, fill: .swatch(.rugB), width: 1.5))
        shapes.append(ArtShape(.rect(mat.insetBy(3), radius: 2.5), stroke: .swatch(.white), lineWidth: 1.1, dash: 2.4))
        return shapes
    }

    static func wallFurniture(_ layout: OfficeLayout, lighting: Lighting = .day, lounge: Bool = true) -> [ArtLayer] {
        // 벽시계 (풍경 창과 화이트보드 사이) · 화이트보드 (윗변 y = wallArtTop) · 출입문 · 탕비 코너
        var shapes = clock(at: layout.clockCenter)
        shapes += whiteboard(at: MapPoint(layout.whiteboardX, OfficeLayout.wallArtTop))
        shapes += door(x: layout.doorX)
        shapes += pantry().transformed(offset: MapPoint(layout.pantryX - pantryDesignX, 0))
        // 벽 앞 꾸밈 (걷는 영역보다 위): 화이트보드와 문 사이 우산꽂이, 문과 냉장고 사이 게시판, 소파와 안마 의자 사이 큰 화분
        shapes += umbrellaStand(at: MapPoint(layout.doorX - 24, OfficeLayout.wallBottom + 7))
        shapes += noticeBoard(centerX: layout.doorX + OfficeLayout.doorWidth + (OfficeLayout.doorToPantry - OfficeLayout.doorWidth) / 2)
        if lounge {
            let gap = (OfficeLayout.sofaArea.maxX + OfficeLayout.massageArea.x) / 2
            shapes += floorPlant(at: MapPoint(gap, OfficeLayout.wallBottom + 9))
        }
        // 풍경 창 (뒷벽 왼쪽, 가로로 긴 창): 낮에는 정원, 밤에는 밤하늘
        let window = lighting == .night ? nightWindow(in: layout.gardenFrame) : garden(in: layout.gardenFrame)
        return [ArtLayer("wall", depth: -.infinity, window + shapes.lit(lighting))]
    }

    /// 풍경 창 (낮): 하늘과 뭉게구름, 겹친 언덕, 빨간 지붕 집, 나무, 꽃, 오솔길. 그 위에 창살·커튼·창턱.
    static func garden(in frame: MapRect) -> [ArtShape] {
        let x = frame.x, y = frame.y, w = frame.width, h = frame.height
        let ix = x + 7, iy = y + 7, iw = w - 14, ih = h - 14
        let dressing = windowDressing(frame)
        var shapes: [ArtShape] = dressing.back + [
            .rect(ix, iy, iw, ih, r: 3, fill: .color(ArtColor(0xDDF0F7)), outline: false),
            .rect(ix, iy + ih * 0.28, iw, ih * 0.4, fill: .color(ArtColor(0xEAF6F4)), outline: false),
            .circle(ix + iw * 0.84, iy + 14, 10.5, fill: .swatch(.butter), outline: false, opacity: 0.35),
            .circle(ix + iw * 0.84, iy + 14, 7, fill: .swatch(.butter), width: 1.1),
        ]
        shapes += cloud(ix + iw * 0.2, iy + 15, 1.15) + cloud(ix + iw * 0.52, iy + 11, 0.85, opacity: 0.92) + cloud(ix + iw * 0.68, iy + 19, 0.6, opacity: 0.85)
        // 새 두 마리
        let bx = ix + iw * 0.36, by = iy + 13
        shapes.append(.line("M\(bx),\(by) q2,-2.4 4,0 q2,-2.4 4,0 M\(bx + 11),\(by + 4) q1.6,-2 3.2,0 q1.6,-2 3.2,0", width: 0.9, opacity: 0.55))
        shapes += [
            // 뒤 언덕 → 앞 언덕
            .path("M\(ix),\(iy + ih * 0.62) C\(ix + iw * 0.25),\(iy + ih * 0.30) \(ix + iw * 0.55),\(iy + ih * 0.62) \(ix + iw * 0.75),\(iy + ih * 0.42) "
                + "C\(ix + iw * 0.88),\(iy + ih * 0.32) \(ix + iw),\(iy + ih * 0.48) \(ix + iw),\(iy + ih * 0.48) L\(ix + iw),\(iy + ih) L\(ix),\(iy + ih) Z",
                  fill: .color(ArtColor(0xA9DDB9)), outline: false),
        ]
        // 뒤 언덕 위의 집과 뾰족한 나무
        let hx = ix + iw * 0.4, hy = iy + ih * 0.53
        shapes += [
            .rect(hx - 6.5, hy - 8, 13, 9, r: 0.8, fill: .color(ArtColor(0xFFF8EE)), width: 1),
            .path("M\(hx - 8.6),\(hy - 7.4) L\(hx),\(hy - 15) L\(hx + 8.6),\(hy - 7.4) Z", fill: .swatch(.alert), width: 1),
            .rect(hx - 4.4, hy - 4.8, 3.2, 5.8, fill: .swatch(.woodDark), outline: false),
            .rect(hx + 1, hy - 5.4, 3.6, 3.2, fill: .swatch(.skyBlue), width: 0.7),
        ]
        for (fx, fy, scale) in [(0.55, 0.58, 1.0), (0.59, 0.56, 0.75), (0.47, 0.54, 0.7)] {
            let tx = ix + iw * fx, base = iy + ih * fy
            shapes += [
                .path("M\(tx - 4.6 * scale),\(base) L\(tx),\(base - 10 * scale) L\(tx + 4.6 * scale),\(base) Z", fill: .color(leafDeep), width: 0.9),
                .path("M\(tx - 3.6 * scale),\(base - 5.6 * scale) L\(tx),\(base - 14 * scale) L\(tx + 3.6 * scale),\(base - 5.6 * scale) Z", fill: .color(leafDeep), width: 0.9),
            ]
        }
        shapes += [
            .path("M\(ix),\(iy + ih * 0.80) C\(ix + iw * 0.30),\(iy + ih * 0.58) \(ix + iw * 0.62),\(iy + ih * 0.86) \(ix + iw),\(iy + ih * 0.66) "
                + "L\(ix + iw),\(iy + ih) L\(ix),\(iy + ih) Z",
                  fill: .color(ArtColor(0x86C9A9)), outline: false),
            // 오솔길
            .path("M\(ix + iw * 0.46),\(iy + ih) C\(ix + iw * 0.50),\(iy + ih * 0.86) \(ix + iw * 0.58),\(iy + ih * 0.80) \(ix + iw * 0.62),\(iy + ih * 0.74) "
                + "L\(ix + iw * 0.65),\(iy + ih * 0.75) C\(ix + iw * 0.63),\(iy + ih * 0.84) \(ix + iw * 0.60),\(iy + ih * 0.92) \(ix + iw * 0.58),\(iy + ih) Z",
                  fill: .color(ArtColor(0xF6E8CB)), outline: false),
        ]
        // 둥근 나무 (줄기 + 겹친 잎)
        for (fx, scale) in [(0.13, 1.0), (0.29, 0.8), (0.79, 0.95), (0.92, 0.7)] {
            let tx = ix + iw * fx
            let base = iy + ih * 0.72
            shapes += [
                .rect(tx - 1.8, base - 12 * scale, 3.6, 12 * scale, r: 1.5, fill: .swatch(.woodDark), outline: false),
                .circle(tx, base - 18 * scale, 10 * scale, fill: .swatch(.mint), width: 1.1),
                .circle(tx - 4.6 * scale, base - 14.6 * scale, 5.6 * scale, fill: .color(leafMid), outline: false),
                .circle(tx + 3.6 * scale, base - 21.6 * scale, 3 * scale, fill: .color(ArtColor(0xBDE6D8)), outline: false),
            ]
        }
        // 꽃
        let flowers: [(Double, Double, Swatch)] = [
            (0.06, 0.90, .pink), (0.18, 0.86, .butter), (0.24, 0.93, .peach), (0.38, 0.88, .pink),
            (0.70, 0.90, .butter), (0.76, 0.84, .pink), (0.88, 0.92, .peach), (0.96, 0.86, .butter),
        ]
        for (fx, fy, color) in flowers {
            shapes.append(.circle(ix + iw * fx, iy + ih * fy, 2.4, fill: .swatch(color), width: 0.8))
            shapes.append(.circle(ix + iw * fx, iy + ih * fy, 0.8, fill: .swatch(.white), outline: false))
        }
        return shapes + dressing.front
    }

    // MARK: - 밤 (M6(6))

    /// 밤 풍경 창: 남색 하늘, 별, 초승달, 어두운 언덕, 불 켜진 집과 먼 마을 불빛. 별은 반짝이지 않습니다 (계속 다시 그리지 않게).
    /// 창틀·커튼·창턱은 낮 그림을 밤 팔레트로 칠해 씁니다.
    static func nightWindow(in frame: MapRect) -> [ArtShape] {
        let x = frame.x, y = frame.y, w = frame.width, h = frame.height
        let ix = x + 7, iy = y + 7, iw = w - 14, ih = h - 14
        let sky = ArtColor(0x27315E)
        let dressing = windowDressing(frame)
        let ink = Paint.color(NightPalette.color(Swatch.ink.color))
        var shapes: [ArtShape] = dressing.back.lit(.night) + [
            .rect(ix, iy, iw, ih, r: 3, fill: .color(sky), outline: false),
            .rect(ix, iy + ih * 0.55, iw, ih * 0.45, fill: .color(ArtColor(0x33407A)), outline: false, opacity: 0.6),
        ]
        // 별: 창 폭에 따라 늘어나는 고정 배치 (같은 창이면 늘 같은 자리)
        let count = max(8, Int(iw / 20))
        for index in 0..<count {
            let fx = (Double(index) + 0.5) / Double(count) + (Double(StableHashLite.value("star-x\(index)") % 60) / 1000 - 0.03)
            let fy = 0.08 + Double(StableHashLite.value("star-y\(index)") % 42) / 100
            let radius = 0.8 + Double(StableHashLite.value("star-r\(index)") % 9) / 10
            let opacity = 0.6 + Double(StableHashLite.value("star-o\(index)") % 40) / 100
            shapes.append(.circle(ix + iw * min(max(fx, 0.02), 0.98), iy + 4 + ih * fy, radius, fill: .color(ArtColor(0xFFF6D8)), outline: false, opacity: opacity))
        }
        // 초승달 (옅은 달무리 → 달 원 위에 하늘색 원을 겹침)
        let moon = MapPoint(ix + iw * 0.84, iy + 15)
        shapes += [
            .circle(moon.x, moon.y, 12, fill: .color(ArtColor(0xFFF1B8)), outline: false, opacity: 0.12),
            ArtShape(.circle(center: moon, radius: 8), fill: .color(ArtColor(0xFFF1B8)), stroke: ink, lineWidth: 1.1),
            .circle(moon.x + 4, moon.y - 3, 7, fill: .color(sky), outline: false),
        ]
        // 언덕 (뒤 → 앞), 뒤 언덕 위의 불 켜진 집
        let hx = ix + iw * 0.4, hy = iy + ih * 0.57
        shapes += [
            .path("M\(ix),\(iy + ih * 0.66) C\(ix + iw * 0.25),\(iy + ih * 0.40) \(ix + iw * 0.55),\(iy + ih * 0.70) \(ix + iw * 0.75),\(iy + ih * 0.50) "
                + "C\(ix + iw * 0.88),\(iy + ih * 0.42) \(ix + iw),\(iy + ih * 0.56) \(ix + iw),\(iy + ih * 0.56) L\(ix + iw),\(iy + ih) L\(ix),\(iy + ih) Z",
                  fill: .color(ArtColor(0x2F4E57)), outline: false),
            .rect(hx - 6.5, hy - 8, 13, 9, r: 0.8, fill: .color(ArtColor(0x3D4A6B)), outline: false),
            .path("M\(hx - 8.6),\(hy - 7.4) L\(hx),\(hy - 15) L\(hx + 8.6),\(hy - 7.4) Z", fill: .color(ArtColor(0x4A3F5E)), outline: false),
            .rect(hx + 1, hy - 5.4, 3.6, 3.2, fill: .color(ArtColor(0xFFD27A)), outline: false),
            .rect(hx - 4.4, hy - 4.8, 3.2, 3.2, fill: .color(ArtColor(0xFFD27A)), outline: false, opacity: 0.8),
            .path("M\(ix),\(iy + ih * 0.84) C\(ix + iw * 0.30),\(iy + ih * 0.66) \(ix + iw * 0.62),\(iy + ih * 0.90) \(ix + iw),\(iy + ih * 0.72) "
                + "L\(ix + iw),\(iy + ih) L\(ix),\(iy + ih) Z",
                  fill: .color(ArtColor(0x253F49)), outline: false),
        ]
        // 먼 마을 불빛
        for (fx, fy) in [(0.18, 0.78), (0.21, 0.80), (0.52, 0.84), (0.55, 0.82), (0.83, 0.76), (0.90, 0.80)] {
            shapes.append(.rect(ix + iw * fx, iy + ih * fy, 2.4, 2.4, fill: .color(ArtColor(0xFFD27A)), outline: false))
        }
        return shapes + dressing.front.lit(.night)
    }

    /// 은은한 불빛: 같은 중심의 반투명 타원을 겹쳐 가운데가 밝고 가장자리로 갈수록 옅어지게 합니다 (렌더러에 그라데이션이 없어도 됨)
    static func glow(_ center: MapPoint, rx: Double, ry: Double, color: ArtColor, opacity: Double, rings: Int = 14) -> [ArtShape] {
        (0..<rings).map { ring in
            let scale = 1 - Double(ring) / Double(rings) * 0.85
            return .ellipse(center.x, center.y, rx * scale, ry * scale, fill: .color(color), opacity: opacity)
        }
    }

    static let lampLight = ArtColor(0xFFD98A)
    static let screenLight = ArtColor(0x9FE6FF)

    /// 사람 있는 책상의 불빛 (밤): 따뜻한 스탠드 빛 웅덩이와 노트북 화면의 푸른 빛. (x, y)는 앉은 직원의 발 위치입니다.
    /// 바닥·러그 위, 의자·책상·직원 아래에 그립니다.
    public static func deskLight(at seat: MapPoint) -> [ArtShape] {
        glow(MapPoint(seat.x, seat.y - 34), rx: 82, ry: 62, color: lampLight, opacity: 0.045)
            + glow(MapPoint(seat.x - 27, seat.y - 50), rx: 30, ry: 22, color: screenLight, opacity: 0.08, rings: 8)
    }

    /// 불을 켤 책상: 그 책상 자리에 서거나 앉아 있는(걷는 중이 아닌) 직원이 있는 책상의 자리(발 위치)
    public static func litDesks(stage: Stage) -> [MapPoint] {
        let standing = stage.actors.values.filter { !$0.isWalking }.map(\.position)
        var lit: [MapPoint] = []
        for row in stage.layout.rows {
            for desk in 0..<row.desks {
                let seat = MapPoint(OfficeLayout.deskX(desk), row.deskY)
                if standing.contains(where: { $0.distance(to: seat) < 2 }) { lit.append(seat) }
            }
        }
        return lit
    }

    /// 소파 옆 스탠드 자리 (두 소파 사이, 발 위치)
    static var floorLampFoot: MapPoint {
        let sofas = OfficeLayout.sofas
        return MapPoint((sofas[0].maxX + sofas[1].x) / 2, 212)
    }

    static func loungeGlow() -> [ArtShape] {
        let sofas = OfficeLayout.sofaArea
        let massage = OfficeLayout.massageArea
        return glow(MapPoint(floorLampFoot.x, 196), rx: sofas.width * 0.5, ry: 64, color: lampLight, opacity: 0.035)
            + glow(MapPoint(massage.x + massage.width / 2, massage.y + massage.height / 2 - 10), rx: massage.width * 0.55, ry: 56, color: lampLight, opacity: 0.026)
    }

    /// 스탠드: 받침, 기둥, 켜진 갓 (밤에만)
    static func floorLamp(at foot: MapPoint) -> [ArtShape] {
        let x = foot.x, y = foot.y
        let ink = Paint.color(NightPalette.color(Swatch.ink.color))
        return [
            ArtShape(.rect(MapRect(x - 1.5, y - 92, 3, 90), radius: 0), fill: .color(ArtColor(0x7A6E8E)), stroke: ink, lineWidth: 1),
            ArtShape(.ellipse(center: MapPoint(x, y - 2), rx: 10, ry: 3.5), fill: .color(ArtColor(0x7A6E8E)), stroke: ink, lineWidth: 1.2),
            ArtShape(.path(VectorPath.parse("M\(x - 14),\(y - 90) L\(x + 14),\(y - 90) L\(x + 9),\(y - 110) L\(x - 9),\(y - 110) Z")),
                     fill: .color(ArtColor(0xFFE3A3)), stroke: ink, lineWidth: 1.4),
        ]
    }

    /// 탕비 코너 그림의 왼쪽 끝 x (아래 도형들은 x 908부터 `OfficeLayout.pantryWidth`만큼의 폭에 그린 좌표입니다)
    static let pantryDesignX = 908.0

    /// 탕비 코너 (오른쪽 벽): 냉장고(위에 화분, 문에 자석·사진), 정수기, 프린터(받침장 위)와 그 위 벽 선반
    static func pantry() -> [ArtShape] {
        let appliance = Paint.color(ArtColor(0xF4F7F8))
        let applianceShade = Paint.color(ArtColor(0xDDE4E8))
        var shapes: [ArtShape] = []
        // 냉장고 위: 늘어진 덩굴 화분과 바구니
        shapes += [
            .line("M922,24 C914,26 913,36 915,46", width: 1.3, color: .color(stemGreen)),
            .circle(914.6, 34, 2.6, fill: .color(leafLight), width: 1),
            .circle(915.4, 44, 2.4, fill: .color(leafMid), width: 1),
            .circle(924, 14.5, 5, fill: .color(leafMid), width: 1.2),
            .circle(932, 11.5, 5.6, fill: .color(leafLight), width: 1.2),
            .circle(939, 15, 4.6, fill: .color(leafDeep), width: 1.2),
        ]
        shapes += pot(width: 15, height: 9, fill: Swatch.pot.color, rim: potLight, line: 1.2).transformed(offset: MapPoint(931, 32))
        shapes += [
            .rect(952, 20, 20, 12, r: 2.4, fill: .swatch(.woodTop), width: 1.3),
            .line("M952,24.6 H972 M958.6,20 V32 M965.4,20 V32", width: 0.9, color: .swatch(.woodDark)),
        ]
        shapes += [
            // 냉장고 (위 냉동칸, 아래 냉장칸)
            .rect(908, 32, 72, 128, r: 9, fill: appliance),
            .rect(972.6, 38, 4, 116, r: 2, fill: applianceShade, outline: false),
            .line("M908,78 L980,78", width: 1.6),
            .rect(966, 46, 4.4, 22, r: 2.2, fill: .swatch(.metal), width: 1.1),
            .rect(966, 88, 4.4, 30, r: 2.2, fill: .swatch(.metal), width: 1.1),
            // 자석, 사진, 쪽지
            .circle(921, 50, 3.6, fill: .swatch(.peach), width: 1),
            .path("M933,58 l2.6,-4.4 l2.6,4.4 z", fill: .swatch(.mint), width: 1),
            .rect(917, 92, 13, 15, r: 1.2, fill: .swatch(.white), width: 1),
            .rect(918.8, 93.8, 9.4, 8.4, fill: .swatch(.sky), outline: false),
            .circle(923.4, 98.6, 2, fill: .swatch(.butter), outline: false),
            .rect(935, 98, 11, 11, r: 1.2, fill: .swatch(.butter), width: 1),
            .line("M937.4,102 h6 M937.4,105 h4", width: 0.8, color: .swatch(.plateInk), opacity: 0.6),
            .circle(940.6, 97.6, 1.5, fill: .swatch(.alert), width: 0.8),
            .circle(924, 120, 3.2, fill: .swatch(.lavender), width: 1),
            .line("M916,156.4 H972", width: 1.2, color: applianceShade),
            // 정수기: 물통(물결·반짝임·공기 방울) → 본체 → 조작판 → 물받이
            .rect(1008, 40, 28, 52, r: 10, fill: .swatch(.drop), opacity: 0.85),
            .rect(1010.4, 42.4, 23.2, 8, r: 4, fill: .swatch(.white), outline: false, opacity: 0.55),
            .rect(1013, 54, 4.4, 26, r: 2.2, fill: .swatch(.white), outline: false, opacity: 0.6),
            .circle(1027, 72, 1.7, fill: .swatch(.white), outline: false, opacity: 0.75),
            .circle(1023.4, 64, 1.2, fill: .swatch(.white), outline: false, opacity: 0.75),
            .circle(1028, 58, 0.9, fill: .swatch(.white), outline: false, opacity: 0.75),
            .rect(1014, 86, 16, 8, r: 2, fill: .swatch(.metal), width: 1.2),
            .rect(998, 92, 48, 68, r: 7, fill: appliance),
            .rect(1039.6, 98, 3.6, 56, r: 1.8, fill: applianceShade, outline: false),
            .rect(1006, 104, 32, 17, r: 4, fill: .swatch(.rackDark), outline: false),
            .rect(1011.4, 108, 5.4, 8, r: 1.6, fill: .swatch(.skyBlue), outline: false),
            .rect(1025.4, 108, 5.4, 8, r: 1.6, fill: .swatch(.alert), outline: false),
            .rect(1011.4, 116, 5.4, 2.4, fill: .swatch(.metalDot), outline: false),
            .rect(1025.4, 116, 5.4, 2.4, fill: .swatch(.metalDot), outline: false),
            .rect(1008, 136, 28, 4.4, r: 2.2, fill: .swatch(.metal), width: 1),
            // 물받이 위의 종이컵
            .path("M1018.6,129 h7 l-1,7 h-5 z", fill: .swatch(.white), width: 1),
            // 프린터 받침장 (문 두 짝)
            .rect(1060, 118, 50, 42, r: 5, fill: .swatch(.wood)),
            .rect(1058, 112, 54, 8, r: 3, fill: .swatch(.woodTop)),
            .line("M1085,122 V157", width: 1.2, color: .swatch(.woodDark)),
            .circle(1081, 138, 1.5, fill: .swatch(.woodDark), outline: false),
            .circle(1089, 138, 1.5, fill: .swatch(.woodDark), outline: false),
            // 프린터: 뒤로 꽂힌 종이, 본체, 조작판, 앞으로 나온 인쇄물
            .rect(1070, 68, 30, 18, r: 1.5, fill: .swatch(.white), width: 1.2),
            .line("M1075,73 h20 M1075,77 h14", width: 0.8, color: .swatch(.plateInk), opacity: 0.45),
            .rect(1062, 80, 46, 32, r: 6, fill: .color(ArtColor(0xE6EAEE))),
            .rect(1062.9, 80.9, 44.2, 7.6, r: 4, fill: .color(ArtColor(0xCDD4DB)), outline: false),
            .rect(1090, 92, 13, 7, r: 2, fill: .swatch(.screenGlow), width: 1),
            .circle(1070, 95.5, 2.4, fill: .swatch(.mint), width: 0.9),
            .circle(1078, 95.5, 2.4, fill: .swatch(.alert), width: 0.9),
            .rect(1068, 103, 34, 4, r: 2, fill: .swatch(.rackDark), outline: false),
            .rect(1071, 105, 28, 10, r: 1.5, fill: .swatch(.white), width: 1.1),
            .line("M1075,109 L1094,109 M1075,112 L1088,112", width: 0.8),
        ]
        shapes += shelf(x: 1056, y: 50)
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
    static func fitted(_ text: String, size: Double, maxWidth: Double, measure: ((String) -> Double)? = nil) -> (String, Double) {
        let measure = measure ?? { estimatedWidth($0, size: size) }
        let full = measure(text)
        if full <= maxWidth { return (text, full) }
        var cut = text
        while !cut.isEmpty, measure(cut + "…") > maxWidth { cut.removeLast() }
        // "파일 …"처럼 말줄임 앞에 빈칸이 남지 않게 (개선 8)
        while cut.last?.isWhitespace == true { cut.removeLast() }
        let result = cut + "…"
        return (result, measure(result))
    }

    /// 책상 하나: 의자(직원 뒤, 깊이 y-1)와 책상(직원 앞, 깊이 y+3). (x, y)는 앉은 직원의 발 위치입니다.
    static func desk(_ name: String, x: Double, y: Double, chair: Int, plate: String?, plant: Bool) -> [ArtLayer] {
        // 상판(위 11pt)과 앞판: 폭과 위·아래 끝은 길찾기 장애물(`OfficeLayout.deskFootprint`)과 같은 값
        let width = OfficeLayout.deskWidth
        let left = x - width / 2
        let top = y + OfficeLayout.deskTop
        var desk: [ArtShape] = [
            .rect(left, top, width, 11, r: 4, fill: .swatch(.woodTop)),
            .rect(left, top + 9, width, y + OfficeLayout.deskBottom - (top + 9), r: 5, fill: .swatch(.wood)),
            // 상판의 빛 줄과 앞판 안쪽 홈
            .line("M\(left + 6),\(top + 3.4) H\(left + 26) M\(left + 30),\(top + 3.4) H\(left + 33)", width: 1.3, color: .swatch(.plate), opacity: 0.75),
            ArtShape(.rect(MapRect(left + 5, top + 13.5, width - 10, 18), radius: 3.5), stroke: .swatch(.woodDark), lineWidth: 1.1, opacity: 0.6),
            // 노트북 (뒷면: 덮개와 로고, 아래에 본체)
            .rect(x - 42, y - 33.6, 30, 3.2, r: 1.6, fill: .color(ArtColor(0xD3D8E3)), width: 1.1),
            .rect(x - 40, y - 46, 26, 14, r: 3, fill: .swatch(.metal)),
            .circle(x - 27, y - 39, 2.1, fill: .swatch(.metalDot), outline: false),
        ]
        if let plate {
            let (text, textWidth) = fitted(plate, size: plateFontSize, maxWidth: width - 4 - 2 * platePadding)
            let width = max(textWidth, 28) + 2 * platePadding
            // 책상 앞판에서 보이는 부분(상판 아래 y-22 ~ y+3)의 세로 가운데보다 조금 위에 답니다
            // (상판 테두리 때문에 기하학적 가운데는 화면에서 아래로 치우쳐 보입니다)
            let plateCenter = y - 9.5 - plateLift
            desk += [
                .rect(x - width / 2, plateCenter - 7.5, width, 15, r: 4, fill: .swatch(.plate), width: 1.2),
                .text(text, x, plateCenter + plateTextDrop, size: plateFontSize, bold: true, baseline: .central),
            ]
        }
        // 상판 오른쪽 뒤: 메인 책상은 화분, 서브 책상은 자리마다 다른 소품
        if plant {
            desk += self.plant(at: MapPoint(x + 29, y - 31), scale: 0.42)
        } else {
            desk += deskItem(chair, at: MapPoint(x + 28, y - 30.5))
        }
        let chairColor = ArtColor(chairColors[chair % 4])
        return [
            ArtLayer("chair-\(name)", depth: y - 1, [
                // 책상 아래 바닥의 옅은 그늘 → 의자 등받이 (안쪽 쿠션, 윗선 빛)
                .rect(left + 3, y + OfficeLayout.deskBottom - 3, width - 6, 7.5, r: 3.5, fill: .swatch(.shadow), outline: false, opacity: 0.6),
                .rect(x - 17, y - 60, 34, 36, r: 11, fill: .color(chairColor)),
                .rect(x - 12, y - 55.5, 24, 24, r: 7.5, fill: .color(chairColor.mixed(with: ArtColor(0xFFFFFF), amount: 0.28)), outline: false),
                .line("M\(x - 6),\(y - 51.6) H\(x + 3)", width: 1.4, color: .swatch(.white), opacity: 0.7),
            ]),
            ArtLayer("desk-\(name)", depth: y + 3, desk),
        ]
    }

    // MARK: - 행

    /// 행 하나: 책상(사람 수만큼, 0번 = 메인), 숨긴 사람이 있으면 행 끝 "+N".
    /// 메인 책상 아래 폴더 이름 표지는 조명을 스스로 맞추므로 `layers`가 따로 붙입니다 (`sign`).
    static func row(_ row: OfficeLayout.Row, team: Team?, plates: [Seat: String]) -> [ArtLayer] {
        var layers: [ArtLayer] = []
        let y = row.deskY
        for desk in 0..<row.desks {
            layers += self.desk(
                "\(row.team.raw)-\(desk)", x: OfficeLayout.deskX(desk), y: y, chair: desk + (team?.colorIndex ?? 0),
                plate: plates[Seat(desk: desk)], plant: desk == 0)
        }
        if row.hidden > 0 {
            layers.append(ArtLayer("row-more-\(row.team.raw)", depth: -.infinity, more(row.hidden, at: MapPoint(row.endX + 26, y - 18))))
        }
        return layers
    }

    /// 행 표지 글자 크기 (M6(8): 9pt 보통 → 10.5pt 굵게)
    static let signFontSize = 10.5
    /// 행 표지 글자 최대 폭 (넘으면 "…", 굵은 글자 기준 영문 약 22자)
    static let signMaxTextWidth = 136.0
    /// 행 표지 높이와 위치 (책상 앞판 아래 끝에서 4pt 아래부터)
    static let signHeight = 20.0
    static let signTop = OfficeLayout.deskBottom + 4
    /// 행 표지 글자 앞 여백 (폴더 아이콘 자리)과 뒤 여백
    static let signTextInset = 20.0
    static let signTrailing = 10.0
    /// 세션 제목 줄 (개선 8): 9pt 보통 글자, 표지 높이 20 → 30
    static let signTitleFontSize = 9.0
    static let signTitleHeight = 30.0
    static let signTitleMiddle = 21.0
    /// 세션 제목 글자 최대 폭. 제목 줄이 메인 책상과 그 옆 틈 안에 들어가 첫 서브 책상 앞까지 뻗지 않게 합니다
    /// (책상 간격 110 − 틈 4 − 여백 30 = 76, 한글 약 9자).
    static let signTitleMaxWidth = OfficeLayout.deskSpacing + OfficeLayout.mainGap - 4 - signTextInset - signTrailing

    /// 행 표지 (메인 책상 바로 아래, M6(8) 행 색 칩): 행 색 바탕 + 폴더 아이콘 + 굵은 폴더 이름.
    /// 행 러그와 같은 색이라 어느 줄의 폴더인지 이어 보이고, 모서리를 6으로 줄여 상태 칩(알약)과 모양을 달리합니다.
    /// 밤에도 행 색은 낮 색 그대로 두고(명패처럼 밝게), 테두리·글자만 밤 잉크로 칠합니다. 이미 조명을 맞춘 색이므로 `lit`을 거치지 않습니다.
    ///
    /// 같은 폴더의 행이 둘 이상 보이면 `title`(메인 세션 제목)을 폴더 이름 아래 둘째 줄에 작게 덧붙입니다 (개선 8).
    /// 제목 줄은 `signTitleMaxWidth`까지 줄이고(말줄임), 폴더 이름 줄의 폭 규칙은 그대로입니다.
    static func sign(
        _ label: String, title: String? = nil, at desk: MapPoint, color: Int, lighting: Lighting = .day, contrast: Bool = false
    ) -> [ArtShape] {
        let (text, textWidth) = fitted(label, size: signFontSize, maxWidth: signMaxTextWidth) {
            TextMetrics.width($0, size: signFontSize, bold: true)
        }
        let subtitle = title.map { title in
            fitted(title, size: signTitleFontSize, maxWidth: signTitleMaxWidth) { TextMetrics.width($0, size: signTitleFontSize) }
        }
        let width = max(textWidth, subtitle?.1 ?? 0) + signTextInset + signTrailing
        let x = desk.x - OfficeLayout.deskWidth / 2
        let top = desk.y + signTop
        let middle = top + signHeight / 2
        let night = lighting == .night
        let ink: Paint = night ? .color(NightPalette.color(Swatch.ink.color)) : .swatch(.ink)
        let paper: Paint = night ? .color(NightPalette.color(Swatch.plate.color)) : .swatch(.plate)
        let swatch = Swatch.team(color)
        let fill: Paint = night ? .color(swatch.color) : .swatch(swatch)
        var shapes: [ArtShape] = [
            ArtShape(
                .rect(MapRect(x, top, width, subtitle == nil ? signHeight : signTitleHeight), radius: 6), fill: fill, stroke: ink,
                lineWidth: contrast ? 2.2 : 1.4),
            folderIcon(center: MapPoint(x + 11, middle + 0.3), ink: ink, fill: paper),
            .text(text, x + signTextInset, middle + plateTextDrop, size: signFontSize, bold: true, color: ink, anchor: .start, baseline: .central),
        ]
        if let subtitle {
            shapes.append(.text(
                subtitle.0, x + signTextInset, top + signTitleMiddle + plateTextDrop, size: signTitleFontSize, color: ink, anchor: .start,
                baseline: .central))
        }
        return shapes
    }

    /// 폴더 아이콘 (폭 10, 높이 7.4): 왼쪽 위 탭이 있는 서류철
    static func folderIcon(center c: MapPoint, ink: Paint, fill: Paint) -> ArtShape {
        let x = c.x - 5, y = c.y - 3.6
        return .path(
            "M\(n(x)) \(n(y)) h3.6 l1.3 1.4 h5.1 v5.8 h-10 z", fill: fill, width: 1.1, stroke: ink)
    }

    static func n(_ value: Double) -> String { VectorPath.format(value) }

    /// 대비 증가 (M6(7)): 명패 바탕(`plate`)을 쓴 도형(책상 명패, 행 표지, "+N")의 잉크 테두리를 2.2pt로
    static func boostPlates(_ layer: ArtLayer) -> ArtLayer {
        var layer = layer
        layer.shapes = layer.shapes.map { shape in
            guard shape.fill == .swatch(.plate), shape.stroke != nil else { return shape }
            var shape = shape
            shape.lineWidth = max(shape.lineWidth, 2.2)
            return shape
        }
        return layer
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

    // MARK: - 휴게 공간 (위쪽 왼쪽, 뒷벽 앞): 3인용 소파 둘 · 빈 공간 · 안마 의자 둘

    static let massageSeat = OfficeLayout.massageSeat

    static func lounge() -> [ArtLayer] {
        var layers: [ArtLayer] = []
        // 3인용 소파 (앉는 자리는 `OfficeLayout.sofaSeatY`): 등받이는 앉은 직원 뒤, 앉는 판과 팔걸이는 앞
        let seatY = OfficeLayout.sofaSeatY
        let seats = OfficeLayout.sofaSeatOffsets
        let sofaDeep = ArtColor(0x9C8FCF), sofaLight = ArtColor(0xB3A7E2), sofaSeam = ArtColor(0x8679BE), sofaShine = ArtColor(0xC9BFEE)
        for (index, sofa) in OfficeLayout.sofas.enumerated() {
            let x = sofa.x
            let y = sofa.y
            let w = sofa.width
            var back: [ArtShape] = [
                .rect(x + 6, y + 4, w - 12, 38, r: 16, fill: .color(sofaDeep)),
                .line("M\(x + 24),\(y + 8.4) H\(x + w - 24)", width: 1.6, color: .color(sofaShine)),
            ]
            // 등받이 솔기 (앉는 자리 사이)
            for (a, b) in zip(seats, seats.dropFirst()) {
                back.append(.line("M\(x + (a + b) / 2),\(y + 12) V\(y + 32)", width: 1.3, color: .color(sofaSeam)))
            }
            // 양 끝 쿠션 (누가 앉으면 가려집니다)
            back += [
                .rect(x + 15, y + 17, 18, 16, r: 4.5, fill: .swatch(index == 0 ? .butter : .mint), width: 1.5),
                .line("M\(x + 19),\(y + 21) l10,8 M\(x + 29),\(y + 21) l-10,8", width: 1, color: .swatch(.white), opacity: 0.8),
                .rect(x + w - 33, y + 18, 18, 16, r: 4.5, fill: .swatch(index == 0 ? .pink : .peach), width: 1.5),
                .circle(x + w - 28, y + 23, 1.2, fill: .swatch(.white), outline: false),
                .circle(x + w - 21, y + 23, 1.2, fill: .swatch(.white), outline: false),
                .circle(x + w - 24.5, y + 28, 1.2, fill: .swatch(.white), outline: false),
            ]
            layers.append(ArtLayer("sofa-back-\(index)", depth: y + 16, back))
            // 직원(앉는 자리) 바로 앞, 앉은 다리(앉는 자리 + CharacterArt.seatedLegsDepth)보다 뒤
            var front: [ArtShape] = [
                // 나무 다리 → 앉는 판
                .rect(x + 16, y + 54, 6, 7, r: 2, fill: .swatch(.woodDark), width: 1.4),
                .rect(x + w - 22, y + 54, 6, 7, r: 2, fill: .swatch(.woodDark), width: 1.4),
                .rect(x + 10, y + 32, w - 20, 26, r: 10, fill: .color(sofaLight)),
                .line("M\(x + 22),\(y + 36.4) H\(x + w - 22)", width: 1.4, color: .color(sofaShine)),
            ]
            // 앉는 자리 사이 칸막이 선
            for (a, b) in zip(seats, seats.dropFirst()) {
                front.append(.rect(x + (a + b) / 2 - 1, y + 39, 2, 16, r: 1, fill: .color(sofaDeep), outline: false))
            }
            front += [
                .rect(x - 2, y + 16, 18, 44, r: 9, fill: .color(sofaDeep)),
                .rect(x + w - 16, y + 16, 18, 44, r: 9, fill: .color(sofaDeep)),
                .line("M\(x + 3.4),\(y + 22) q3.6,-3.4 7.2,0 M\(x + w - 10.6),\(y + 22) q3.6,-3.4 7.2,0", width: 1.4, color: .color(sofaShine)),
            ]
            layers.append(ArtLayer("sofa-front-\(index)", depth: seatY + 1.5, front))
        }
        // 안마 의자: 등판·팔걸이(직원 뒤) → 롤러(움직임, liveLayers) → 직원 → 앉는 판·발판(앞) → 앉은 다리
        // 팔걸이는 팔꿈치 높이(발 위치 -30)로 낮춰 직원 뒤에 그립니다: 안마 자세의 팔(30°)이 팔걸이 위에 얹히고, 몸통 옆을 가리지 않습니다.
        // 앉는 판은 몸통 아랫단(-14)에 살짝만 걸쳐(-16) 배를 덮지 않고, 그 위를 앉은 다리의 허벅지가 덮습니다 (M6(2)).
        let shell = ArtColor(0x6F86A8), pad = ArtColor(0x8EA6C8), seam = ArtColor(0x7B93B6), shine = ArtColor(0xAFC3DF)
        for (index, s) in OfficeLayout.massageSeats.enumerated() {
            layers.append(ArtLayer("massage-back-\(index)", depth: s.y - 1, [
                .rect(s.x - 26, s.y - 98, 52, 80, r: 16, fill: .color(shell)),
                .rect(s.x - 20, s.y - 90, 40, 64, r: 12, fill: .color(pad), outline: false),
                // 등판 누빔 선
                .line("M\(s.x - 8),\(s.y - 72) H\(s.x + 8) M\(s.x - 8),\(s.y - 56) H\(s.x + 8) M\(s.x - 8),\(s.y - 40) H\(s.x + 8)", width: 1.2, color: .color(seam)),
                // 머리 받침
                .rect(s.x - 18, s.y - 108, 36, 18, r: 9, fill: .color(pad)),
                .line("M\(s.x - 9),\(s.y - 103.6) H\(s.x + 5)", width: 1.4, color: .color(shine)),
                // 팔걸이와 조작 단추
                .rect(s.x - 37, s.y - 30, 15, 26, r: 7, fill: .color(shell)),
                .rect(s.x + 22, s.y - 30, 15, 26, r: 7, fill: .color(shell)),
                .line("M\(s.x - 33),\(s.y - 25.6) q3.4,-2.6 6.8,0 M\(s.x + 26.2),\(s.y - 25.6) q3.4,-2.6 6.8,0", width: 1.3, color: .color(shine)),
                .rect(s.x + 25, s.y - 18.6, 9, 6.4, r: 2.4, fill: .swatch(.rackDark), outline: false),
                .circle(s.x + 27.6, s.y - 15.4, 1.3, fill: .swatch(.mint), outline: false),
                .circle(s.x + 31.4, s.y - 15.4, 1.3, fill: .swatch(.butter), outline: false),
            ]))
            layers.append(ArtLayer("massage-front-\(index)", depth: s.y + 1, [
                .rect(s.x - 25, s.y - 16, 50, 13, r: 6, fill: .color(pad)),
                .line("M\(s.x - 17),\(s.y - 12.4) H\(s.x + 12)", width: 1.3, color: .color(shine)),
                .rect(s.x - 14, s.y - 4, 28, 12, r: 5, fill: .color(shell)),
                .line("M\(s.x - 8),\(s.y + 2.4) H\(s.x + 8)", width: 1.2, color: .color(seam)),
            ]))
        }
        return layers
    }

    /// 안마 의자 등판 롤러 두 개. 누가 앉아 있으면 위아래로 오르내리고, 비어 있으면 위쪽에 멈춰 있습니다.
    static func massageRoller(at s: MapPoint = massageSeat, time: Double?) -> [ArtShape] {
        let phase = time.map { (1 - cos($0 * 2 * Double.pi / 2.6)) / 2 } ?? 0
        // 0.25pt 단위로 맞춰 같은 위치면 같은 그림이 되게 합니다 (앱이 구운 텍스처를 다시 씀, M6(1))
        let y = s.y - 82 + quarter(phase * 46)
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
            .rect(x - 36, y - 40, max(1.5, quarter(18 * progress)), 3, r: 1.5, fill: .swatch(.drop), outline: false),
            .circle(x - 19, y - 36, 1.4, fill: .swatch(blink ? .butter : .metalDot), outline: false),
        ]
    }

    /// 0.25pt 단위로 반올림 (움직이는 가구가 부동소수점 오차로 매번 다른 그림이 되지 않게)
    static func quarter(_ value: Double) -> Double {
        (value * 4).rounded() / 4
    }
}
