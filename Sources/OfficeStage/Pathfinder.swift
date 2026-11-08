import Foundation

/// 걸을 수 있는 칸 위에서 A*로 길을 찾고, 직선으로 이을 수 있는 구간은 줄여서 자연스럽게 걷게 합니다.
/// (설계서는 GameplayKit을 썼지만, Linux에서도 테스트하려고 직접 구현했습니다)
public struct Pathfinder: Sendable {
    public let layout: OfficeLayout
    private let grid: [Bool]
    private let columns: Int
    private let rows: Int

    public init(layout: OfficeLayout) {
        self.layout = layout
        grid = layout.walkableGrid()
        columns = layout.gridColumns
        rows = layout.gridRows
    }

    public func isWalkable(column: Int, row: Int) -> Bool {
        column >= 0 && row >= 0 && column < columns && row < rows && grid[row * columns + column]
    }

    /// `from`에서 `to`까지 지나갈 점들 (시작점 제외, 도착점 포함). 길이 없으면 바로 도착점으로 갑니다.
    public func route(from start: MapPoint, to goal: MapPoint) -> [MapPoint] {
        guard start.distance(to: goal) > 0.5 else { return [] }
        if lineIsWalkable(start, goal) { return [goal] }
        guard let startCell = nearestWalkable(to: start), let goalCell = nearestWalkable(to: goal),
            let cells = search(from: startCell, to: goalCell)
        else { return [goal] }
        var points = [start] + cells.map { layout.cellCenter(column: $0.0, row: $0.1) } + [goal]
        points = smooth(points)
        return Array(points.dropFirst())
    }

    public func length(of path: [MapPoint], from start: MapPoint) -> Double {
        var total = 0.0
        var previous = start
        for point in path {
            total += previous.distance(to: point)
            previous = point
        }
        return total
    }

    // MARK: -

    private func nearestWalkable(to point: MapPoint) -> (Int, Int)? {
        let (column, row) = layout.cell(for: point)
        if isWalkable(column: column, row: row) { return (column, row) }
        for radius in 1..<max(columns, rows) {
            var best: (Int, Int)?
            var bestDistance = Double.infinity
            for dy in -radius...radius {
                for dx in -radius...radius where abs(dx) == radius || abs(dy) == radius {
                    let c = column + dx
                    let r = row + dy
                    guard isWalkable(column: c, row: r) else { continue }
                    let distance = layout.cellCenter(column: c, row: r).distance(to: point)
                    if distance < bestDistance {
                        best = (c, r)
                        bestDistance = distance
                    }
                }
            }
            if let best { return best }
        }
        return nil
    }

    private func search(from start: (Int, Int), to goal: (Int, Int)) -> [(Int, Int)]? {
        let startIndex = start.1 * columns + start.0
        let goalIndex = goal.1 * columns + goal.0
        var open = MinHeap()
        var cameFrom = [Int](repeating: -1, count: columns * rows)
        var cost = [Double](repeating: .infinity, count: columns * rows)
        var closed = [Bool](repeating: false, count: columns * rows)
        cost[startIndex] = 0
        open.push(startIndex, priority: heuristic(start, goal))

        let steps: [(Int, Int, Double)] = [
            (1, 0, 1), (-1, 0, 1), (0, 1, 1), (0, -1, 1),
            (1, 1, 1.4142), (1, -1, 1.4142), (-1, 1, 1.4142), (-1, -1, 1.4142),
        ]
        while let current = open.pop() {
            if current == goalIndex { break }
            if closed[current] { continue }
            closed[current] = true
            let column = current % columns
            let row = current / columns
            for (dx, dy, stepCost) in steps {
                let c = column + dx
                let r = row + dy
                guard isWalkable(column: c, row: r) else { continue }
                // 대각선으로 모서리를 깎지 않습니다
                if dx != 0, dy != 0, !isWalkable(column: column + dx, row: row) || !isWalkable(column: column, row: row + dy) { continue }
                let next = r * columns + c
                let candidate = cost[current] + stepCost
                if candidate < cost[next] {
                    cost[next] = candidate
                    cameFrom[next] = current
                    open.push(next, priority: candidate + heuristic((c, r), goal))
                }
            }
        }
        guard startIndex == goalIndex || cameFrom[goalIndex] >= 0 else { return nil }
        var path: [(Int, Int)] = []
        var node = goalIndex
        while node != startIndex, node >= 0 {
            path.append((node % columns, node / columns))
            node = cameFrom[node]
        }
        return path.reversed()
    }

    private func heuristic(_ a: (Int, Int), _ b: (Int, Int)) -> Double {
        let dx = Double(abs(a.0 - b.0))
        let dy = Double(abs(a.1 - b.1))
        return max(dx, dy) + 0.4142 * min(dx, dy)
    }

    /// 걸을 수 있는 칸만 지나는 직선인지 (4pt 간격으로 확인)
    public func lineIsWalkable(_ a: MapPoint, _ b: MapPoint) -> Bool {
        let distance = a.distance(to: b)
        let steps = max(Int(distance / 4), 1)
        for step in 0...steps {
            let t = Double(step) / Double(steps)
            let point = a + (b - a) * t
            // 시작·도착 칸은 가구와 겹쳐도 됩니다 (의자, 소파 자리)
            if step == 0 || step == steps { continue }
            let (column, row) = layout.cell(for: point)
            if !isWalkable(column: column, row: row) { return false }
        }
        return true
    }

    private func smooth(_ points: [MapPoint]) -> [MapPoint] {
        guard points.count > 2 else { return points }
        var result = [points[0]]
        var anchor = 0
        while anchor < points.count - 1 {
            var next = points.count - 1
            while next > anchor + 1, !lineIsWalkable(points[anchor], points[next]) {
                next -= 1
            }
            result.append(points[next])
            anchor = next
        }
        return result
    }
}

/// A*용 이진 힙
private struct MinHeap {
    private var items: [(index: Int, priority: Double)] = []

    mutating func push(_ index: Int, priority: Double) {
        items.append((index, priority))
        var child = items.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard items[child].priority < items[parent].priority else { break }
            items.swapAt(child, parent)
            child = parent
        }
    }

    mutating func pop() -> Int? {
        guard !items.isEmpty else { return nil }
        let top = items[0].index
        let last = items.removeLast()
        if !items.isEmpty {
            items[0] = last
            var parent = 0
            while true {
                let left = parent * 2 + 1
                let right = left + 1
                var smallest = parent
                if left < items.count, items[left].priority < items[smallest].priority { smallest = left }
                if right < items.count, items[right].priority < items[smallest].priority { smallest = right }
                guard smallest != parent else { break }
                items.swapAt(parent, smallest)
                parent = smallest
            }
        }
        return top
    }
}
