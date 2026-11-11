import Foundation

/// 경과 시간 글자 한 벌 (개선 9). 메뉴·사무실 창 패널·미니 머리줄·인스펙터·현황 줄이 모두 이것을 씁니다.
///
/// - 지속(`duration`): 일이 시작된 뒤 "12초째" → "3분째" → "1시간 5분째" → "3일 2시간째"
/// - 지난(`ago`): 끝난 일이 지난 뒤 "방금" → "12초 전" → "3분 전" → "2시간 전" → "3일 전"
///
/// 글자가 바뀌는 때는 `nextChange`가 알려 줍니다 (창은 이때만 다시 그림, 설계서 §8.3).
/// 글자 규칙을 바꾸면 `nextChange`의 단계도 함께 맞춥니다 (테스트가 경계에서 둘을 같이 확인합니다).
public enum ElapsedText {
    /// "12초째", "3분째", "1시간 5분째", "3일 2시간째". 1초 미만은 nil.
    /// - Parameter showSeconds: false면 1분 미만도 nil (30초·1분마다 갱신하는 화면용)
    public static func duration(_ seconds: TimeInterval, showSeconds: Bool = true) -> String? {
        let total = whole(seconds)
        if total < 1 { return nil }
        if total < 60 { return showSeconds ? "\(total)초째" : nil }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes)분째" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)시간 \(minutes % 60)분째" }
        return "\(hours / 24)일 \(hours % 24)시간째"
    }

    /// "방금", "12초 전", "3분 전", "2시간 전", "3일 전".
    /// - Parameter showSeconds: false면 1분 미만은 모두 "방금" (1분마다 갱신하는 화면용)
    public static func ago(_ seconds: TimeInterval, showSeconds: Bool = true) -> String {
        let total = whole(seconds)
        if total < (showSeconds ? 5 : 60) { return "방금" }
        if total < 60 { return "\(total)초 전" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes)분 전" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)시간 전" }
        return "\(hours / 24)일 전"
    }

    /// `start`부터 센 글자가 `now` 다음에 처음 바뀌는 때.
    /// 지속은 1분 미만 1초, 하루 미만 1분(분이 보임), 그 뒤 1시간 단위. 지난은 1분 미만 1초(`showSeconds`가 false면 1분), 1시간 미만 1분, 그 뒤 1시간 단위.
    public static func nextChange(since start: Date, after now: Date, isDuration: Bool, showSeconds: Bool = true) -> Date {
        let elapsed = max(now.timeIntervalSince(start), 0)
        let step: TimeInterval
        if elapsed < 60 { step = (isDuration || showSeconds) ? 1 : 60 }
        else if elapsed < (isDuration ? 86_400 : 3_600) { step = 60 }
        else { step = 3_600 }
        return start.addingTimeInterval(((elapsed / step).rounded(.down) + 1) * step)
    }

    private static func whole(_ seconds: TimeInterval) -> Int {
        seconds.isFinite ? Int(max(0, seconds)) : 0
    }
}
