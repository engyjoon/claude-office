import Foundation
import Testing
@testable import OfficeCore

@Suite("경과 시간 글자 (개선 9)")
struct ElapsedTextTests {
    private static let minute = 60.0, hour = 3600.0, day = 86_400.0

    @Test("지속 \"N분째\": 경계값", arguments: [
        (0.4, nil), (1, "1초째"), (59, "59초째"), (60, "1분째"), (59 * 60 + 59, "59분째"),
        (60 * 60, "1시간 0분째"), (23 * 3600 + 59 * 60, "23시간 59분째"), (24 * 3600, "1일 0시간째"),
        (3 * 86_400 + 2 * 3600 + 59, "3일 2시간째"), (72 * 3600, "3일 0시간째"),
        (185, "3분째"), (3720, "1시간 2분째"), (-5, nil), (.infinity, nil),
    ] as [(TimeInterval, String?)])
    func duration(seconds: TimeInterval, expected: String?) {
        #expect(ElapsedText.duration(seconds) == expected)
    }

    @Test("지속: 초를 숨기면 1분 미만은 없음")
    func durationWithoutSeconds() {
        #expect(ElapsedText.duration(59, showSeconds: false) == nil)
        #expect(ElapsedText.duration(60, showSeconds: false) == "1분째")
        #expect(ElapsedText.duration(4320 * 60, showSeconds: false) == "3일 0시간째")
    }

    @Test("지난 \"N분 전\": 경계값", arguments: [
        (-3, "방금"), (4.9, "방금"), (5, "5초 전"), (59, "59초 전"), (60, "1분 전"), (59 * 60 + 59, "59분 전"),
        (3600, "1시간 전"), (23 * 3600 + 59 * 60 + 59, "23시간 전"), (24 * 3600, "1일 전"),
        (3 * 86_400 + 5, "3일 전"), (7200, "2시간 전"), (12, "12초 전"),
    ] as [(TimeInterval, String)])
    func ago(seconds: TimeInterval, expected: String) {
        #expect(ElapsedText.ago(seconds) == expected)
    }

    @Test("지난: 초를 숨기면 1분 미만은 \"방금\"")
    func agoWithoutSeconds() {
        #expect(ElapsedText.ago(59, showSeconds: false) == "방금")
        #expect(ElapsedText.ago(60, showSeconds: false) == "1분 전")
    }

    /// 다시 그리는 때(`nextChange`)마다 글자가 실제로 바뀌고, 그 사이에는 안 바뀌어야 한다.
    @Test("nextChange: 글자가 바뀌는 순간에 맞는다", arguments: [true, false], [true, false])
    func nextChangeMatchesText(isDuration: Bool, showSeconds: Bool) {
        let start = Date(timeIntervalSinceReferenceDate: 1_000_000)
        func text(_ at: TimeInterval) -> String? {
            isDuration ? ElapsedText.duration(at, showSeconds: showSeconds) : ElapsedText.ago(at, showSeconds: showSeconds)
        }
        // 0.5초 간격으로 4일을 훑으며, 글자가 바뀐 모든 순간이 nextChange에 있는지 확인
        var now = start
        var shown = text(0)
        var scheduled = ElapsedText.nextChange(since: start, after: now, isDuration: isDuration, showSeconds: showSeconds)
        let end = start.addingTimeInterval(4 * Self.day)
        var step = 0
        while now < end {
            now = now.addingTimeInterval(step < 4000 ? 0.5 : 30)
            step += 1
            let current = text(now.timeIntervalSince(start))
            if current != shown {
                #expect(now >= scheduled.addingTimeInterval(-0.001), "예정보다 먼저 바뀜 \(now.timeIntervalSince(start))초")
                shown = current
            }
            if now >= scheduled {
                scheduled = ElapsedText.nextChange(since: start, after: now, isDuration: isDuration, showSeconds: showSeconds)
            }
            #expect(scheduled > now)
        }
    }

    @Test("nextChange: 단계 경계")
    func nextChangeSteps() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        func next(_ s: TimeInterval, _ d: Bool, _ sec: Bool = true) -> TimeInterval {
            ElapsedText.nextChange(since: t0, after: t0.addingTimeInterval(s), isDuration: d, showSeconds: sec).timeIntervalSince(t0)
        }
        #expect(next(12.3, true) == 13)
        #expect(next(59.5, true) == 60)
        #expect(next(61, true) == 120)
        #expect(next(3700, true) == 3720)          // "1시간 1분째" → 2분째
        #expect(next(86_400 + 10, true) == 86_400 + 3600)
        #expect(next(10, false) == 11)
        #expect(next(10, false, false) == 60)      // 초를 숨기면 "방금" → 1분 전
        #expect(next(3700, false) == 7200)         // "1시간 전" → "2시간 전"
    }
}
