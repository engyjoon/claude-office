import Foundation
import OfficeCore

/// 직원이 서는 자리. `approach`까지는 길찾기로 걷고, 마지막에 `final`로 한 걸음 들어갑니다.
/// (책상 뒤 의자, 소파처럼 가구와 겹치는 자리 때문입니다)
public struct Place: Hashable, Sendable {
    public var final: MapPoint
    public var approach: MapPoint
    /// 여러 직원이 같은 자리에 서지 않도록 예약할 때 쓰는 키
    public var key: String?
    /// 행 안의 책상이면 그 행과 책상 (사무실 크기가 바뀔 때 자리를 다시 계산하고, 책상이 쓰이는지 셀 때 씀)
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

/// 사무실 배치 (설계서 §8.1, M5(1)). 3/4 탑다운 맵이고, 크기는 사무실 창(화면) 크기를 그대로 따릅니다 (배율 1).
///
/// ```
/// ┌───────────────────────────────────────────────────────────────────────────────┐
/// │ [──── 정원 그림 액자 ────]    시계    [화이트보드]      [출입문]  [냉장고][정수기][프린터] │ ← 뒷벽
/// │ [3인용 소파][3인용 소파]   (빈 공간)   [안마 의자][안마 의자]          (탕비 코너)        │ ← 공용 공간 (위쪽)
/// │ ★메인1  서브1  서브2  서브3                                                    │ ← 행 1
/// │ ★메인2  서브1  서브2  서브3  서브4  서브5  서브6  서브7  서브8  서브9  +3        │ ← 행 2
/// │ ★메인3  서브                                                                   │ ← 행 3 (최대 3행)
/// └───────────────────────────────────────────────────────────────────────────────┘
/// ```
///
/// - 행 하나 = 메인 하나: 가장 왼쪽 책상이 메인, 오른쪽으로 그 메인의 서브 책상이 사람 수만큼 (빈 책상 없음).
/// - 행은 메인이 온 순서대로 위에서 아래로 쌓고, 최대 3행까지 보여 줍니다. 화면에 들어가지 않는 행·서브는 그리지 않고
///   행 끝에 "+N"을 답니다 (판단은 `FloorPlan`).
/// - 행 간격은 화면 높이를 따라 3행이 아래 빈 공간까지 고르게 쓰도록 벌어집니다 (최소 `minRowSpacing`).
/// - 공용 공간(휴게 공간: 3인용 소파 둘 · 빈 공간 · 안마 의자 둘, 화이트보드, 출입문, 탕비 코너)은 모두 위쪽 뒷벽 앞에 모았습니다.
///   책장은 없앴습니다 (파일 읽기는 자기 책상에서).
public struct OfficeLayout: Hashable, Sendable {
    public static let tile = 16.0
    public static let wallBottom = 160.0
    public static let walkTop = 172.0
    /// 첫 행의 책상 줄 y (앉은 직원의 발 위치)
    public static let firstDeskY = 342.0
    /// 행 간격의 최솟값. 화면이 높으면 3행이 아래 빈 공간까지 고르게 쓰도록 더 벌립니다 (`rowSpacing(height:)`).
    public static let minRowSpacing = 150.0
    /// 한 화면에 보여 주는 최대 행 수 (2026-11-08 결정)
    public static let maxRows = 3
    /// 메인 책상 x
    public static let firstDeskX = 70.0
    /// 사무실 둘레 여백 (위·아래·왼쪽·오른쪽). 화면(사무실 영역)에서 이만큼 안쪽에 사무실을 놓고, 여백에는 벽·바닥만 이어 그립니다.
    public static let padding = 20.0
    /// 메인 책상과 첫 서브 책상 사이에 더 띄우는 간격
    public static let mainGap = 18.0
    public static let deskSpacing = 92.0
    public static let deskWidth = 82.0
    public static let approachOffset = 46.0
    /// 행 끝 "+N" 표시 자리
    public static let moreBadgeWidth = 46.0
    /// 맨 아래 행 밑의 여백
    public static let bottomMargin = 36.0
    /// 이보다 작은 화면에서는 사무실을 줄여서 보여 줍니다. 폭은 휴게 공간과 뒷벽 가구(정원 액자·화이트보드·출입문·탕비 코너)가 겹치지 않는 최소 크기,
    /// 높이는 3행(`maxRows`)이 최소 간격으로 모두 들어가는 크기입니다 (사무실 창도 이보다 낮아지지 않게 막습니다).
    public static let minWidth = massageArea.maxX - 20 + whiteboardToDoor + doorToPantry + 212
    public static let minHeight = firstDeskY + minRowSpacing * Double(maxRows - 1) + bottomMargin
    /// 창을 처음 열었을 때의 사무실 크기 (창 1440×800 − 디렉토리·세션 패널 260 − 제목 막대 − 둘레 여백)
    public static let defaultWidth = 1140.0
    public static let defaultHeight = 708.0

    /// 휴게 공간 (위쪽 왼쪽, 2026-11-08 셋째 수정): 소파 구역(3인용 소파 둘) → 빈 공간 → 안마 구역(안마 의자 둘)
    public static let lounge = MapRect(0, 160, 600, 100)
    /// 3인용 소파 둘 (앉는 자리는 소파마다 세 곳). 사이를 36pt 띄웁니다.
    public static let sofas = [MapRect(14, 168, 136, 56), MapRect(186, 168, 136, 56)]
    /// 소파 구역 (러그)
    public static let sofaArea = MapRect(6, 176, 324, 78)
    /// 안마 구역 (러그). 소파 구역과 빈 공간을 두고 떨어져 있습니다.
    public static let massageArea = MapRect(392, 172, 200, 84)
    /// 안마 의자에 앉는 자리 (발 위치), 의자마다 하나. 의자 사이를 44pt 띄웁니다.
    public static let massageSeats = [MapPoint(440, 236), MapPoint(544, 236)]
    /// 첫 안마 의자 자리 (테스트·그림에서 씀)
    public static var massageSeat: MapPoint { massageSeats[0] }
    static func massageChair(_ seat: MapPoint) -> MapRect { MapRect(seat.x - 30, seat.y - 50, 60, 58) }

    /// 화면에 들어가는 수
    public struct Capacity: Hashable, Sendable {
        /// 한 행의 책상 수 (메인 포함)
        public var columns: Int
        public var rows: Int

        public init(columns: Int, rows: Int) {
            self.columns = columns
            self.rows = rows
        }
    }

    /// 화면(사무실 영역) 크기에 들어가는 책상 수와 행 수. 배율 1 기준이고, 최소 크기보다 작으면 최소 크기로 셉니다.
    public static func capacity(width: Double, height: Double) -> Capacity {
        let w = max(width, minWidth)
        let h = max(height, minHeight)
        let room = w - 8 - moreBadgeWidth - deskWidth / 2 - firstDeskX - mainGap
        let columns = 1 + max(0, Int((room / deskSpacing).rounded(.down)))
        let rows = 1 + max(0, Int(((h - bottomMargin - firstDeskY) / minRowSpacing).rounded(.down)))
        return Capacity(columns: columns, rows: min(maxRows, rows))
    }

    /// 화면 높이에 맞춘 행 간격: 3행이 첫 행부터 아래 여백까지 고르게 들어가게 벌리고, 최소 `minRowSpacing`.
    public static func rowSpacing(height: Double) -> Double {
        max(minRowSpacing, ((max(height, minHeight) - bottomMargin - firstDeskY) / Double(maxRows - 1)).rounded(.down))
    }

    /// 화면에 그릴 배율. 사무실은 화면 크기를 따라가므로 언제나 1이고, 화면이 최소 크기보다 작을 때만 줄입니다.
    /// (행이 닫히는 동안 잠깐 행이 하나 더 있어도 배율을 바꾸지 않고 아래를 잘라 보여 줍니다)
    public static func displayScale(viewWidth: Double, viewHeight: Double) -> Double {
        min(1, max(viewWidth, 1) / minWidth, max(viewHeight, 1) / minHeight)
    }

    /// 행 하나 (메인 하나와 그 서브들)
    public struct Row: Hashable, Sendable {
        public var team: TeamID
        /// 책상 수 (메인 포함, 1 이상)
        public var desks: Int
        /// 화면에 다 못 보여 줘서 숨긴 사람 수 ("+N")
        public var hidden: Int
        /// 위에서부터 몇 번째 행인지
        public var index: Int
        /// 행 간격 (화면 높이를 따름)
        public var spacing: Double = OfficeLayout.minRowSpacing

        public var deskY: Double { OfficeLayout.firstDeskY + spacing * Double(index) }
        /// 행이 차지하는 띠 (책상 뒤 통로부터 책상 앞까지)
        public var top: Double { deskY - 90 }
        public var bottom: Double { deskY + 40 }
        public func deskX(_ desk: Int) -> Double { OfficeLayout.deskX(desk) }
        /// 행 끝 (마지막 책상 오른쪽 가장자리)
        public var endX: Double { deskX(desks - 1) + OfficeLayout.deskWidth / 2 }
    }

    /// 행을 만들 때 필요한 정보
    public struct Room: Hashable, Sendable {
        public var team: TeamID
        public var desks: Int
        public var hidden: Int

        public init(team: TeamID, desks: Int, hidden: Int = 0) {
            self.team = team
            self.desks = desks
            self.hidden = hidden
        }
    }

    public let width: Double
    public let height: Double
    /// 행 간격 (화면 높이를 따름)
    public let rowSpacing: Double
    public private(set) var rows: [Row]

    /// - Parameters:
    ///   - width, height: 화면(사무실 영역) 크기. 최소 크기보다 작으면 최소 크기로 만듭니다.
    ///   - rooms: 위에서부터 놓을 행
    public init(width: Double = OfficeLayout.defaultWidth, height: Double = OfficeLayout.defaultHeight, rooms: [Room] = []) {
        self.width = max(width.rounded(), Self.minWidth)
        let spacing = Self.rowSpacing(height: height.rounded())
        rowSpacing = spacing
        rows = rooms.enumerated().map { index, room in
            Row(team: room.team, desks: max(1, room.desks), hidden: max(0, room.hidden), index: index, spacing: spacing)
        }
        let needed = Self.firstDeskY + spacing * Double(max(rows.count, 1) - 1) + Self.bottomMargin
        self.height = max(height.rounded(), Self.minHeight, needed)
    }

    public var rooms: [Room] { rows.map { Room(team: $0.team, desks: $0.desks, hidden: $0.hidden) } }
    public var capacity: Capacity { Self.capacity(width: width, height: height) }

    public func row(for team: TeamID) -> Row? {
        rows.first { $0.team == team }
    }

    /// 행이 없을 때 쓰는 첫 행 자리
    var firstRow: Row { rows.first ?? Row(team: TeamID(""), desks: 1, hidden: 0, index: 0, spacing: rowSpacing) }

    public static func deskX(_ desk: Int) -> Double {
        firstDeskX + (desk > 0 ? mainGap : 0) + deskSpacing * Double(desk)
    }

    // MARK: - 자리

    /// 행 안의 책상. 행이 아직 배치에 없으면 첫 행 기준으로 계산합니다.
    public func seat(_ team: TeamID, _ seat: Seat) -> Place {
        Self.seat(row(for: team) ?? firstRow, seat, team: team)
    }

    public static func seat(_ row: Row, _ seat: Seat, team: TeamID? = nil) -> Place {
        let team = team ?? row.team
        let x = deskX(seat.desk)
        let y = row.deskY
        return Place(final: MapPoint(x, y), approach: MapPoint(x, y - approachOffset), key: "seat:\(team.raw):\(seat.desk)", team: team, seat: seat)
    }

    // MARK: - 뒷벽 가구 (화면 폭에 맞춰 놓음)

    /// 탕비 코너 왼쪽 x (오른쪽 벽에 붙임)
    public var pantryX: Double { width - 212 }
    /// 출입문 왼쪽 x
    public var doorX: Double { pantryX - Self.doorToPantry }
    /// 출입문 왼쪽 → 탕비 코너 왼쪽, 화이트보드 왼쪽 → 출입문 왼쪽 거리 (화이트보드 폭 128 + 넉넉한 사이 72)
    static let doorToPantry = 124.0
    static let whiteboardToDoor = 200.0
    /// 화이트보드 왼쪽 x
    public var whiteboardX: Double { doorX - Self.whiteboardToDoor }
    /// 뒷벽 그림·화이트보드 윗변 y (휴게 공간 가구 등판과 넉넉히 띄우려고 위로 올림)
    public static let wallArtTop = 22.0
    /// 정원 그림 액자 (뒷벽 왼쪽, 가로로 긴 액자, 최대 폭 380). 소파 위에 걸려 안마 의자 등판과 겹치지 않습니다.
    public var gardenFrame: MapRect {
        MapRect(28, Self.wallArtTop, min(380, max(160, whiteboardX - 28 - 100)), 74)
    }
    /// 벽시계 가운데 (정원 액자와 화이트보드 사이 가운데)
    public var clockCenter: MapPoint { MapPoint((gardenFrame.maxX + whiteboardX) / 2, 60) }
    public var doorPoint: MapPoint { MapPoint(doorX + 36, 182) }

    public enum Zone: String, Hashable, Sendable, CaseIterable {
        case whiteboard, lounge, massageChair, pantry
    }

    /// 구역마다 정해진 자리
    public func slots(_ zone: Zone) -> [Place] {
        let points: [(MapPoint, MapPoint?)]
        switch zone {
        case .whiteboard: points = [(MapPoint(whiteboardX + 34, 200), nil), (MapPoint(whiteboardX + 90, 202), nil)]
        case .pantry: points = [(MapPoint(pantryX + 38, 204), nil), (MapPoint(pantryX + 116, 206), nil)]
        case .lounge:
            // 3인용 소파 둘에 세 자리씩, 소파 앞에서 들어가 앉습니다
            points = Self.sofas.flatMap { sofa in
                [sofa.x + 28, sofa.x + 68, sofa.x + 108].map { x in (MapPoint(x, 214), MapPoint(x, 250)) as (MapPoint, MapPoint?) }
            }
        case .massageChair:
            // 의자 앞에서 앉습니다
            points = Self.massageSeats.map { ($0, MapPoint($0.x, 272)) }
        }
        return points.enumerated().map { index, item in
            Place(final: item.0, approach: item.1, key: "\(zone.rawValue):\(index)")
        }
    }

    /// 정해진 자리가 다 찼을 때 서는 자리 (구역 가까운 순). 한 점에 겹쳐 서지 않도록 격자로 흩어 놓습니다.
    public func overflow(_ zone: Zone) -> [Place] {
        let area: MapRect
        switch zone {
        case .whiteboard: area = MapRect(whiteboardX - 10, 222, 150, 40)
        case .pantry: area = MapRect(pantryX, 226, 200, 36)
        case .lounge, .massageChair: area = MapRect(20, 258, 560, 20)
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
        case .whiteboard: .whiteboard
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

    /// 걸어서 지나갈 수 없는 가구 (발 위치 기준)
    public var obstacles: [MapRect] {
        var rects: [MapRect] = []
        for row in rows {
            for desk in 0..<row.desks {
                rects.append(MapRect(Self.deskX(desk) - Self.deskWidth / 2, row.deskY - 33, Self.deskWidth, 38))
            }
        }
        rects += Self.sofas + Self.massageSeats.map(Self.massageChair)
        return rects
    }

    public var gridColumns: Int { Int((width / Self.tile).rounded(.up)) }
    public var gridRows: Int { Int((height / Self.tile).rounded(.up)) }

    public func cellCenter(column: Int, row: Int) -> MapPoint {
        MapPoint((Double(column) + 0.5) * Self.tile, (Double(row) + 0.5) * Self.tile)
    }

    public func cell(for point: MapPoint) -> (column: Int, row: Int) {
        (min(max(Int(point.x / Self.tile), 0), gridColumns - 1), min(max(Int(point.y / Self.tile), 0), gridRows - 1))
    }

    public func isWalkable(_ point: MapPoint) -> Bool {
        guard point.x >= 8, point.x <= width - 8, point.y >= Self.walkTop, point.y <= height - 8 else { return false }
        return !obstacles.contains { $0.contains(point) }
    }

    /// 걸을 수 있는 칸 지도 (행 우선)
    public func walkableGrid() -> [Bool] {
        let obstacles = self.obstacles
        var grid = [Bool](repeating: false, count: gridColumns * gridRows)
        for row in 0..<gridRows {
            for column in 0..<gridColumns {
                let center = cellCenter(column: column, row: row)
                let inside = center.x >= 8 && center.x <= width - 8 && center.y >= Self.walkTop && center.y <= height - 8
                grid[row * gridColumns + column] = inside && !obstacles.contains { $0.insetBy(-4).contains(center) }
            }
        }
        return grid
    }

    // MARK: - 행 옮기기

    /// 이 점이 속한 행
    func rowIndex(containing point: MapPoint) -> Int? {
        rows.firstIndex { point.y >= $0.top && point.y < $0.bottom }
    }
}
