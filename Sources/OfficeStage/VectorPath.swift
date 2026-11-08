import Foundation

/// 벡터 경로 명령 (절대 좌표). SVG 경로 문자열에서 만들고, SVG와 CoreGraphics 양쪽으로 그립니다.
public enum PathCommand: Hashable, Sendable {
    case move(MapPoint)
    case line(MapPoint)
    case quad(control: MapPoint, to: MapPoint)
    case cubic(control1: MapPoint, control2: MapPoint, to: MapPoint)
    case close
}

/// 미리보기(docs/preview)의 SVG 경로를 그대로 옮기기 위한 작은 파서.
/// M/L/H/V/C/S/Q/T/Z와 소문자(상대 좌표)를 지원합니다. 호(A)는 쓰지 않습니다.
public enum VectorPath {
    public static func parse(_ d: String) -> [PathCommand] {
        var tokens = Tokenizer(d)
        var commands: [PathCommand] = []
        var current = MapPoint.zero
        var start = MapPoint.zero
        var lastControl: MapPoint?
        var lastCommand: Character = " "
        var command: Character = "M"

        while let token = tokens.next() {
            switch token {
            case .command(let c):
                command = c
            case .number:
                tokens.pushBack(token)
            }
            let relative = command.isLowercase
            func point() -> MapPoint? {
                guard let x = tokens.number(), let y = tokens.number() else { return nil }
                return MapPoint(x, y) + (relative ? current : .zero)
            }
            switch command.uppercased().first! {
            case "M":
                guard let p = point() else { return commands }
                commands.append(.move(p))
                current = p
                start = p
                lastControl = nil
                // M 뒤에 이어지는 좌표는 L로 취급합니다
                command = relative ? "l" : "L"
                lastCommand = "M"
                continue
            case "L":
                guard let p = point() else { return commands }
                commands.append(.line(p))
                current = p
                lastControl = nil
            case "H":
                guard let x = tokens.number() else { return commands }
                current = MapPoint(relative ? current.x + x : x, current.y)
                commands.append(.line(current))
                lastControl = nil
            case "V":
                guard let y = tokens.number() else { return commands }
                current = MapPoint(current.x, relative ? current.y + y : y)
                commands.append(.line(current))
                lastControl = nil
            case "C":
                guard let c1 = point(), let c2 = point(), let p = point() else { return commands }
                commands.append(.cubic(control1: c1, control2: c2, to: p))
                current = p
                lastControl = c2
            case "S":
                let c1 = "CS".contains(lastCommand) && lastControl != nil ? current * 2 - lastControl! : current
                guard let c2 = point(), let p = point() else { return commands }
                commands.append(.cubic(control1: c1, control2: c2, to: p))
                current = p
                lastControl = c2
            case "Q":
                guard let c = point(), let p = point() else { return commands }
                commands.append(.quad(control: c, to: p))
                current = p
                lastControl = c
            case "T":
                let c = "QT".contains(lastCommand) && lastControl != nil ? current * 2 - lastControl! : current
                guard let p = point() else { return commands }
                commands.append(.quad(control: c, to: p))
                current = p
                lastControl = c
            case "Z":
                commands.append(.close)
                current = start
                lastControl = nil
            default:
                return commands
            }
            lastCommand = Character(command.uppercased())
        }
        return commands
    }

    /// 다시 SVG 경로 문자열로 (디버그 렌더러용)
    public static func svg(_ commands: [PathCommand]) -> String {
        func f(_ p: MapPoint) -> String { "\(format(p.x)),\(format(p.y))" }
        return commands.map { command in
            switch command {
            case .move(let p): "M\(f(p))"
            case .line(let p): "L\(f(p))"
            case .quad(let c, let p): "Q\(f(c)) \(f(p))"
            case .cubic(let c1, let c2, let p): "C\(f(c1)) \(f(c2)) \(f(p))"
            case .close: "Z"
            }
        }.joined(separator: " ")
    }

    public static func transformed(_ commands: [PathCommand], _ transform: (MapPoint) -> MapPoint) -> [PathCommand] {
        commands.map { command in
            switch command {
            case .move(let p): .move(transform(p))
            case .line(let p): .line(transform(p))
            case .quad(let c, let p): .quad(control: transform(c), to: transform(p))
            case .cubic(let c1, let c2, let p): .cubic(control1: transform(c1), control2: transform(c2), to: transform(p))
            case .close: .close
            }
        }
    }

    static func format(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }

    private enum Token: Equatable {
        case command(Character)
        case number(Double)
    }

    private struct Tokenizer {
        let scalars: [Character]
        var index = 0
        var pushed: Token?

        init(_ text: String) {
            scalars = Array(text)
        }

        mutating func pushBack(_ token: Token) {
            pushed = token
        }

        mutating func skipSeparators() {
            while index < scalars.count, scalars[index] == " " || scalars[index] == "," || scalars[index].isNewline || scalars[index] == "\t" {
                index += 1
            }
        }

        mutating func next() -> Token? {
            if let token = pushed {
                pushed = nil
                return token
            }
            skipSeparators()
            guard index < scalars.count else { return nil }
            let c = scalars[index]
            if c.isLetter, c != "e", c != "E" {
                index += 1
                return .command(c)
            }
            return readNumber().map(Token.number)
        }

        mutating func number() -> Double? {
            if let token = pushed {
                pushed = nil
                if case .number(let value) = token { return value }
                pushed = token
                return nil
            }
            skipSeparators()
            return readNumber()
        }

        private mutating func readNumber() -> Double? {
            let begin = index
            var seenDot = false
            var seenExponent = false
            if index < scalars.count, scalars[index] == "-" || scalars[index] == "+" { index += 1 }
            while index < scalars.count {
                let c = scalars[index]
                if c.isNumber {
                    index += 1
                } else if c == ".", !seenDot, !seenExponent {
                    seenDot = true
                    index += 1
                } else if c == "e" || c == "E", !seenExponent {
                    seenExponent = true
                    index += 1
                    if index < scalars.count, scalars[index] == "-" || scalars[index] == "+" { index += 1 }
                } else {
                    break
                }
            }
            guard index > begin else { return nil }
            return Double(String(scalars[begin..<index]))
        }
    }
}
