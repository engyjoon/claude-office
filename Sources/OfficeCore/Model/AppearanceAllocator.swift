import Foundation

/// 사무실 안에서 겹치지 않는 외형을 고릅니다 (설계서 §9.4, M5(6)).
///
/// - 1순위는 키 해시로 나온 외형(`Appearance.make`)입니다. 지금 사무실에 있는 모든 사람과 충분히 다르면 그대로 씁니다.
/// - 겹치면 키에서 정해지는 순서(키로 섞은 모든 조합)로 다음 조합을 보고, 모든 사람과 충분히 다른 첫 조합을 고릅니다.
/// - 충분히 다르다 = 눈에 잘 띄는 네 부위(머리 모양·머리색·상의 색·소품) 중 2군데 이상 다름. 피부색은 세지 않습니다.
/// - 그런 조합이 없으면 1군데만 다른 조합, 그것도 없으면 가장 덜 겹치는 조합으로 물러납니다.
/// - 이미 있는 사람의 외형은 건드리지 않습니다. 같은 입력이면 언제나 같은 결과입니다.
public enum AppearanceAllocator {
    /// 충분히 다르다고 보는 부위 수
    public static let requiredDifference = 2

    /// 기준이 되는 직원 한 명
    public struct Occupant: Sendable {
        public var appearance: Appearance
        /// 같은 행 사람이면 목소리도 되도록 피합니다
        public var sameRow: Bool

        public init(appearance: Appearance, sameRow: Bool) {
            self.appearance = appearance
            self.sameRow = sameRow
        }
    }

    /// 눈에 잘 띄는 부위 중 다른 곳의 수 (0…4). 피부색과 목소리는 세지 않습니다.
    public static func visibleDifference(_ a: Appearance, _ b: Appearance) -> Int {
        (a.hairStyle != b.hairStyle ? 1 : 0) + (a.hairColor != b.hairColor ? 1 : 0)
            + (a.topColor != b.topColor ? 1 : 0) + (a.accessory != b.accessory ? 1 : 0)
    }

    /// 새로 온 사람의 외형을 고릅니다.
    /// - Parameters:
    ///   - key: 외형 키 (`session#<id>`, 에이전트 이름, `temp#<serial>`)
    ///   - occupants: 지금 사무실에 있는 모든 사람 (모든 디렉토리, 쉬는 사람 포함)
    public static func allocate(key: String, kind: StaffKind, among occupants: [Occupant]) -> Appearance {
        let preferred = Appearance.make(key: key, kind: kind)
        let others = occupants.map(\.appearance)
        var best = preferred
        var bestScore = score(preferred, against: others)
        if bestScore != .clear {
            for candidate in candidates(key: key, kind: kind, preferred: preferred) {
                let candidateScore = score(candidate, against: others)
                if candidateScore < bestScore {
                    best = candidate
                    bestScore = candidateScore
                    if bestScore == .clear { break }
                }
            }
        }
        best.voice = voice(preferred: preferred.voice, avoiding: occupants.filter(\.sameRow).map(\.appearance.voice))
        return best
    }

    /// 겹침 정도: 똑같은 사람 수, 그다음 1군데만 다른 사람 수가 적을수록 좋습니다.
    struct Score: Comparable, Equatable {
        var identical: Int
        var close: Int
        static let clear = Score(identical: 0, close: 0)
        static func < (lhs: Score, rhs: Score) -> Bool {
            (lhs.identical, lhs.close) < (rhs.identical, rhs.close)
        }
    }

    static func score(_ appearance: Appearance, against others: [Appearance]) -> Score {
        var result = Score.clear
        for other in others {
            let difference = visibleDifference(appearance, other)
            if difference == 0 { result.identical += 1 }
            if difference < requiredDifference { result.close += 1 }
        }
        return result
    }

    /// 1순위 다음에 볼 조합들: 이 종류가 가질 수 있는 모든 조합을 키로 섞은 순서 (피부색·목소리는 1순위 그대로).
    static func candidates(key: String, kind: StaffKind, preferred: Appearance) -> [Appearance] {
        let accessories: [Accessory?] = kind == .temporary ? [.sprout] : [nil, .glasses, .headphones, .beanie, .ribbon]
        let seed = StableHash.fnv1a("appearance#" + key)
        var all: [(order: UInt64, appearance: Appearance)] = []
        all.reserveCapacity(Appearance.hairStyleCount * Appearance.hairColorCount * Appearance.topColorCount * accessories.count)
        var index: UInt64 = 0
        for hairStyle in 0..<Appearance.hairStyleCount {
            for hairColor in 0..<Appearance.hairColorCount {
                for topColor in 0..<Appearance.topColorCount {
                    for accessory in accessories {
                        index += 1
                        var appearance = preferred
                        appearance.hairStyle = hairStyle
                        appearance.hairColor = hairColor
                        appearance.topColor = topColor
                        appearance.accessory = accessory
                        all.append((StableHash.mix(seed &+ index &* 0x9E37_79B9_7F4A_7C15), appearance))
                    }
                }
            }
        }
        return all.sorted { $0.order < $1.order }.map(\.appearance)
    }

    /// 같은 행에서 아무도 쓰지 않는 목소리 (1순위부터 한 단계씩). 모두 쓰고 있으면 1순위 그대로.
    static func voice(preferred: Int, avoiding used: [Int]) -> Int {
        let taken = Set(used)
        for step in 0..<Appearance.voiceCount {
            let voice = (preferred + step) % Appearance.voiceCount
            if !taken.contains(voice) { return voice }
        }
        return preferred
    }
}
