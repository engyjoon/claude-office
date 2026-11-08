import Foundation
import OfficeCore

/// 직원이 서는 자리. `approach`까지는 길찾기로 걷고, 마지막에 `final`로 한 걸음 들어갑니다.
/// (책상 뒤 의자, 소파처럼 가구와 겹치는 자리 때문입니다)
public struct Place: Hashable, Sendable {
    public var final: MapPoint
    public var approach: MapPoint
    /// 여러 직원이 같은 자리에 서지 않도록 예약할 때 쓰는 키
    public var key: String?
    /// 방 안의 자리이면 그 방과 자리 (사무실 크기가 바뀔 때 자리를 다시 계산하고, 칸이 쓰이는지 셀 때 씀)
    public var team: TeamID?
    public var seat: Seat?

    public init(final: MapPoint, approach: MapPoint? = nil, key: String? = nil, team: TeamID? = nil, seat: Seat? = nil) {
        self.final = final
        self.approach = approach ?? final
        self.key = key
        self.team = team
        self.seat = seat
    }

    func shifted(by dy: Double) -> Place {
        var place = self
        place.final.y += dy
        place.approach.y += dy
        return place
    }
}

/// 사무실 배치 (설계서 §8.1, M4.5b). 폭 1120pt의 3/4 탑다운 맵.
///
/// ```
/// ┌──────────┬───────────────────────────────────────────────────────────────┐
/// │ 액자 시계 │ [책장] [창문][창문]  [화이트보드] [출입문]   [냉장고][정수기]  │ ← 뒷벽
/// │┌────────┐│        ═리서치 데스크═                                         │
/// ││ 팀장실  │   ┌─ 0번 칸: 팀장 파트 ─┐        ┌─ 1번 칸: 파트장1 ─┐       │
/// ││  ★책상  ╎   │ 책상 책상 책상 책상  │        │ ★   책상 책상 책상 │       │
/// │└──────🪴┘│   └─────────────────────┘        └───────────────────┘       │
/// │ 소파 커피 │   ┌─ 2번 칸: 파트장2 ───┐        ┌─ 3번 칸: 빈 칸 ────┐       │
/// │ 안마의자  │   │ ★   책상 책상 책상  │        │ 책상 책상 책상 책상 │       │
/// └──────────┴───────────────────────────────────────────────────────────────┘
/// ```
///
/// - 방(메인 세션) 하나 = 띠 하나: 왼쪽 열의 팀장실 + 오른쪽의 파트 칸(한 줄에 2칸, 칸마다 책상 4개).
///   칸 번호 = 파트 번호(0번 = 팀장 직속 파트). 칸이 모자라면 띠 아래로 줄이 늘고, 맨 아래 줄이 통째로 비면 줄어듭니다.
/// - 첫 띠의 왼쪽 열에는 팀장실 아래 휴게 공간(소파·커피·안마 의자)이 있어 첫 띠는 최소 2줄입니다.
/// - 방이 여럿이면 띠를 아래로 쌓습니다 (M5의 방 선택기 전까지). 방 하나만 그리는 무대는 띠가 하나입니다.
/// - 뒷벽(y < 160)에는 책장·창가 리서치 데스크·화이트보드·출입문·탕비 코너가 있습니다.
public struct OfficeLayout: Hashable, Sendable {
    public static let width = 1120.0
    public static let tile = 16.0
    public static let wallBottom = 160.0
    public static let walkTop = 172.0
    public static let firstDeskY = 346.0
    public static let rowSpacing = 190.0
    /// 왼쪽 열(팀장실·휴게 공간) 폭. 칸막이는 이 x에 섭니다.
    public static let sideWidth = 210.0
    /// 파트 칸 두 열의 가운데 x
    public static let podCentersX = [430.0, 900.0]
    /// 칸 안 책상 x 위치 (칸 가운데 기준). 0번(맨 왼쪽)이 파트장 자리(★)입니다.
    public static let podDeskOffsets = [-138.0, -46.0, 46.0, 138.0]
    public static let deskWidth = 82.0
    public static let approachOffset = 46.0
    /// 팀장실 책상 x
    public static let officeDeskX = 105.0
    public static let doorPoint = MapPoint(828, 182)
    /// 첫 띠 위쪽 경계 (첫 책상 줄 y - 95)
    static let firstBandTop = firstDeskY - 95
    /// 휴게 공간 (첫 띠의 왼쪽 열, 팀장실 아래)
    public static let lounge = MapRect(0, 440, sideWidth, 191)
    /// 안마 의자에 앉는 자리 (발 위치)
    public static let massageSeat = MapPoint(178, 548)
    /// 맨 아래 띠 밑의 여백
    static let bottomMargin = 35.0

    /// 방 하나의 띠
    public struct Band: Hashable, Sendable {
        public var team: TeamID
        /// 파트 칸 수 (언제나 짝수 = 줄 수 × 2)
        public var cells: Int
        /// 띠 위쪽 경계 (첫 책상 줄 y - 95)
        public var top: Double
        public var isFirst: Bool

        /// 줄 수. 첫 띠는 휴게 공간 때문에 최소 2줄입니다 (오른쪽의 칸이 없는 줄은 빈 바닥).
        public var rows: Int { max(cells / 2, isFirst ? 2 : 1) }
        public var bottom: Double { top + OfficeLayout.rowSpacing * Double(rows) }
        public func deskY(row: Int) -> Double { top + 95 + OfficeLayout.rowSpacing * Double(row) }
        /// 팀장실 영역 (칸막이 안쪽)
        public var office: MapRect {
            let y = isFirst ? OfficeLayout.wallBottom : top + 8
            return MapRect(0, y, OfficeLayout.sideWidth, deskY(row: 0) + 86 - y)
        }
        /// 팀장실 출입구 (오른쪽 칸막이의 틈). 책상 뒤 통로 높이에 있어 들어가면 팀장 옆으로 바로 갑니다.
        public var officeDoor: (top: Double, bottom: Double) { (deskY(row: 0) - 78, deskY(row: 0) - 22) }
    }

    /// 방 하나의 띠를 만들 때 필요한 정보
    public struct Room: Hashable, Sendable {
        public var team: TeamID
        public var cells: Int

        public init(team: TeamID, cells: Int) {
            self.team = team
            self.cells = cells
        }
    }

    public private(set) var bands: [Band]

    /// - Parameter rooms: 위에서부터 놓을 방 (칸 수는 짝수로 올립니다)
    public init(rooms: [Room] = []) {
        var top = Self.firstBandTop
        var bands: [Band] = []
        for (index, room) in rooms.enumerated() {
            let band = Band(team: room.team, cells: max(2, (room.cells + 1) / 2 * 2), top: top, isFirst: index == 0)
            bands.append(band)
            top = band.bottom
        }
        self.bands = bands
    }

    public var rooms: [Room] { bands.map { Room(team: $0.team, cells: $0.cells) } }
    /// 전체 줄 수
    public var rows: Int { bands.isEmpty ? 2 : bands.reduce(0) { $0 + $1.rows } }
    public var height: Double { (bands.last?.bottom ?? Self.firstBandTop + Self.rowSpacing * 2) + Self.bottomMargin }

    public func band(for team: TeamID) -> Band? {
        bands.first { $0.team == team }
    }

    /// 방이 없을 때 그리는 첫 띠 (빈 팀장실과 휴게 공간)
    var firstBand: Band {
        bands.first ?? Band(team: TeamID(""), cells: 0, top: Self.firstBandTop, isFirst: true)
    }

    // MARK: - 자리

    /// 파트 칸 가운데 (책상 줄 높이)
    public static func cellCenter(_ band: Band, cell: Int) -> MapPoint {
        MapPoint(podCentersX[cell % 2], band.deskY(row: cell / 2))
    }

    /// 방 안의 자리. 방이 아직 배치에 없으면 첫 띠 기준으로 계산합니다.
    public func seat(_ team: TeamID, _ seat: Seat) -> Place {
        Self.seat(band(for: team) ?? firstBand, seat)
    }

    public static func seat(_ band: Band, _ seat: Seat) -> Place {
        let key = "seat:\(band.team.raw):\(seat.part):\(seat.desk)"
        if seat.isOffice {
            let y = band.deskY(row: 0)
            return Place(final: MapPoint(officeDeskX, y), approach: MapPoint(officeDeskX, y - approachOffset), key: key, team: band.team, seat: seat)
        }
        let center = cellCenter(band, cell: seat.part)
        if seat.desk < podDeskOffsets.count {
            let x = center.x + podDeskOffsets[seat.desk]
            return Place(final: MapPoint(x, center.y), approach: MapPoint(x, center.y - approachOffset), key: key, team: band.team, seat: seat)
        }
        // 책상이 모자라면 칸 앞에 서서 일합니다
        let extra = seat.desk - podDeskOffsets.count
        let x = center.x - 150 + Double(extra % 6) * 60
        let y = center.y + 74 + Double(extra / 6) * 30
        return Place(final: MapPoint(x, y), key: key, team: band.team, seat: seat)
    }

    public enum Zone: String, Hashable, Sendable, CaseIterable {
        case bookshelf, whiteboard, research, lounge, massageChair, pantry
    }

    /// 구역마다 정해진 자리
    public func slots(_ zone: Zone) -> [Place] {
        let points: [(MapPoint, MapPoint?)]
        switch zone {
        case .bookshelf: points = [(MapPoint(246, 200), nil), (MapPoint(292, 206), nil), (MapPoint(338, 200), nil)]
        // 리서치 데스크 뒤(창가 쪽)에 서서 화면 쪽을 봅니다
        case .research: points = [(MapPoint(420, 192), nil), (MapPoint(468, 192), nil), (MapPoint(516, 192), nil), (MapPoint(564, 192), nil)]
        case .whiteboard: points = [(MapPoint(664, 198), nil), (MapPoint(718, 200), nil)]
        case .pantry: points = [(MapPoint(946, 202), nil), (MapPoint(1024, 204), nil)]
        case .lounge:
            // 소파에 앉는 두 자리는 소파 앞에서 들어갑니다
            points = [
                (MapPoint(52, 520), MapPoint(52, 556)), (MapPoint(104, 520), MapPoint(104, 556)),
                (MapPoint(96, 606), nil), (MapPoint(146, 612), nil),
            ]
        case .massageChair:
            // 의자 앞에서 앉습니다
            points = [(Self.massageSeat, MapPoint(Self.massageSeat.x, 584))]
        }
        return points.enumerated().map { index, item in
            Place(final: item.0, approach: item.1, key: "\(zone.rawValue):\(index)")
        }
    }

    /// 정해진 자리가 다 찼을 때 서는 자리 (구역 가까운 순). 한 점에 겹쳐 서지 않도록 격자로 흩어 놓습니다.
    public func overflow(_ zone: Zone) -> [Place] {
        let area: MapRect
        switch zone {
        case .bookshelf: area = MapRect(226, 226, 140, 50)
        case .research: area = MapRect(396, 244, 196, 44)
        case .whiteboard: area = MapRect(636, 224, 136, 50)
        case .pantry: area = MapRect(900, 228, 200, 46)
        case .lounge, .massageChair: area = MapRect(72, 566, 128, 60)
        }
        let anchor = slots(zone)[0].final
        // 정해진 자리와 너무 가까운 점은 빼서 겹쳐 보이지 않게 합니다
        let fixed = Zone.allCases.flatMap { slots($0).flatMap { [$0.final, $0.approach] } }
        var points: [MapPoint] = []
        var y = area.y
        var row = 0
        while y <= area.maxY {
            var x = area.x + (row % 2 == 0 ? 0 : 20)
            while x <= area.maxX {
                let point = MapPoint(x, y)
                if isWalkable(point), !fixed.contains(where: { $0.distance(to: point) < 24 }) { points.append(point) }
                x += 40
            }
            y += 26
            row += 1
        }
        points.sort { ($0.distance(to: anchor), $0.x, $0.y) < ($1.distance(to: anchor), $1.x, $1.y) }
        return points.enumerated().map { Place(final: $1, key: "\(zone.rawValue):x\($0)") }
    }

    public static func zone(for spot: Spot) -> Zone? {
        switch spot {
        case .bookshelf: .bookshelf
        case .whiteboard: .whiteboard
        case .research: .research
        case .lounge: .lounge
        case .massageChair: .massageChair
        case .pantry: .pantry
        case .door, .seat, .beside: nil
        }
    }

    /// 자리 키가 가리키는 구역
    static func zone(ofKey key: String?) -> Zone? {
        guard let key, let name = key.split(separator: ":").first else { return nil }
        return Zone(rawValue: String(name))
    }

    // MARK: - 장애물과 걸을 수 있는 칸

    /// 리서치 데스크 (창가 스탠딩 테이블)
    static let researchDesk = MapRect(392, 206, 196, 26)

    /// 걸어서 지나갈 수 없는 가구 (발 위치 기준)
    public var obstacles: [MapRect] {
        var rects: [MapRect] = []
        let bands = self.bands.isEmpty ? [firstBand] : self.bands
        for band in bands {
            let y = band.deskY(row: 0)
            // 팀장실 책상과 칸막이 (오른쪽은 출입구 틈을 남기고, 아래쪽은 끝까지)
            rects.append(MapRect(Self.officeDeskX - Self.deskWidth / 2, y - 33, Self.deskWidth, 38))
            let office = band.office
            let door = band.officeDoor
            let wallX = Self.sideWidth - 6
            rects.append(MapRect(wallX, office.y, 10, door.top - office.y))
            rects.append(MapRect(wallX, door.bottom, 10, office.maxY - door.bottom))
            rects.append(MapRect(0, office.maxY - 6, Self.sideWidth + 4, 10))
            for cell in 0..<band.cells {
                let center = Self.cellCenter(band, cell: cell)
                for offset in Self.podDeskOffsets {
                    rects.append(MapRect(center.x + offset - Self.deskWidth / 2, center.y - 33, Self.deskWidth, 38))
                }
            }
        }
        rects.append(Self.researchDesk)
        // 휴게 공간: 소파, 안마 의자, 커피 카운터
        rects.append(MapRect(14, 474, 128, 56))
        rects.append(MapRect(148, 500, 60, 58))
        rects.append(MapRect(8, 592, 58, 36))
        return rects
    }

    public var gridColumns: Int { Int(Self.width / Self.tile) }
    public var gridRows: Int { Int((height / Self.tile).rounded(.up)) }

    public func cellCenter(column: Int, row: Int) -> MapPoint {
        MapPoint((Double(column) + 0.5) * Self.tile, (Double(row) + 0.5) * Self.tile)
    }

    public func cell(for point: MapPoint) -> (column: Int, row: Int) {
        (min(max(Int(point.x / Self.tile), 0), gridColumns - 1), min(max(Int(point.y / Self.tile), 0), gridRows - 1))
    }

    public func isWalkable(_ point: MapPoint) -> Bool {
        guard point.x >= 8, point.x <= Self.width - 8, point.y >= Self.walkTop, point.y <= height - 8 else { return false }
        return !obstacles.contains { $0.contains(point) }
    }

    /// 걸을 수 있는 칸 지도 (행 우선)
    public func walkableGrid() -> [Bool] {
        let obstacles = self.obstacles
        var grid = [Bool](repeating: false, count: gridColumns * gridRows)
        for row in 0..<gridRows {
            for column in 0..<gridColumns {
                let center = cellCenter(column: column, row: row)
                let inside = center.x >= 8 && center.x <= Self.width - 8 && center.y >= Self.walkTop && center.y <= height - 8
                grid[row * gridColumns + column] = inside && !obstacles.contains { $0.insetBy(-4).contains(center) }
            }
        }
        return grid
    }

    // MARK: - 띠 옮기기

    /// 이 점이 속한 띠 (첫 띠는 자리가 바뀌지 않으므로 둘째 띠부터 봅니다)
    func bandIndex(containing point: MapPoint) -> Int? {
        for (index, band) in bands.enumerated().dropFirst() where point.y >= band.top && point.y < band.bottom {
            return index
        }
        return nil
    }
}
