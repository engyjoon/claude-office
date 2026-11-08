import Foundation
import OfficeCore

/// 사무실 장면을 얼마나 자주 다시 그릴지 (설계서 §8.3, M6(1))
public enum RenderPace: Int, Comparable, Hashable, Sendable, CustomStringConvertible {
    /// 창이 안 보임 (닫힘·최소화·가려짐·다른 Space): 그리지 않음
    case paused
    /// 보이지만 한동안(`calmAfter`) 아무 일도 없음: 3fps, 깜빡임은 천천히(`calmBlinkDuration`)
    case calm
    /// 보이지만 잔잔함 (쉬는 사람의 숨쉬기·깜빡임·Zz, 컵 홀짝, 모니터 진행 막대): 6fps
    case ambient
    /// 일하는 중 (타이핑 손 흔들림, 승인 대기 손 들기)만 있음: 10fps
    case working
    /// 걷기·제스처·말풍선 톡·종이비행기처럼 빠른 움직임: 30fps
    case active

    /// 초당 그리는 장 수 (멈춤이면 0)
    public var framesPerSecond: Int {
        switch self {
        case .paused: 0
        case .calm: RenderPacer.calmFPS
        case .ambient: RenderPacer.ambientFPS
        case .working: RenderPacer.workingFPS
        case .active: RenderPacer.activeFPS
        }
    }

    public static func < (lhs: RenderPace, rhs: RenderPace) -> Bool { lhs.rawValue < rhs.rawValue }

    public var description: String {
        switch self {
        case .paused: "paused"
        case .calm: "calm"
        case .ambient: "ambient"
        case .working: "working"
        case .active: "active"
        }
    }
}

/// 무대 상태로 그리기 빈도를 정합니다 (순수 함수, 설계서 §8.3 "변화가 없으면 렌더링 일시 정지").
///
/// SpriteKit은 장면 크기와 상관없이 한 장에 약 1.5~2ms(메인 스레드 + Metal·디스플레이 링크)를 써서, 초당 그리는 장 수가 대기 CPU를 거의 정합니다
/// (M6(1) 측정, M4: 미니만 보일 때 장마다 약 0.23%p, 아무것도 안 그릴 때 0.4%).
///
/// - 창이 안 보이면 멈춤.
/// - 빠른 움직임(걷기·제스처·말풍선 톡·종이비행기)이 있거나 훅을 받은 직후 `settleTime` 동안: 30fps.
/// - 일하는 사람의 타이핑(손 4.5° 흔들림, 0.29초 주기)·손 들기(1.1초 주기)만 있으면: 10fps. 바쁜 세션은 대부분 이 상태라
///   30fps면 활동 중 목표(5%)를 넘었습니다 (M6(1) 측정: 30fps 7.7%, 15fps 6%). 타이핑 손은 10fps에서 한 주기에 3장이라
///   고르게 흔들리지 않고 잘게 떨리는데, 빠른 타자로 보여 괜찮습니다. 걷기(120pt/s)는 낮추면 한 장에 몇 pt씩 뛰어 30fps로 둡니다.
/// - 그 밖(쉬는 중): 6fps. 쉬는 사람도 숨쉬기(2.8초 주기, 1.3pt)·깜빡임(0.14초)·Zz 통통(1.8초)·졸며 고개 끄덕(3초)으로
///   계속 조금씩 움직여서 완전히 멈추면 화면이 죽어 보입니다. 숨쉬기는 6fps에서 한 장에 최대 0.25pt(레티나 0.5픽셀)만 움직여 30fps와 구별되지 않습니다.
/// - 쉬는 상태가 `calmAfter`(20초) 넘게 이어지면: 3fps. 숨쉬기가 한 장에 최대 0.5pt(1픽셀) 움직이고, Zz는 조금 뚝뚝 떠오릅니다.
///   0.14초짜리 깜빡임은 3fps에서 대부분 건너뛰므로 이때는 깜빡임을 0.34초로 늘립니다(쉬는 사람이 느리게 깜빡임, 한 장 이상 걸림).
public enum RenderPacer {
    public static let activeFPS = 30
    public static let ambientFPS = 6
    public static let workingFPS = 10
    public static let calmFPS = 3
    /// 연출 지시를 받은 뒤 30fps로 두는 시간 (초)
    public static let settleTime = 0.5
    /// 빠른 움직임·연출 지시가 이만큼(초) 없으면 잠잠함
    public static let calmAfter = 20.0
    /// 잠잠함 단계의 깜빡임 길이 (초, 평소 0.14초). 3fps 한 장 간격(0.33초)보다 길어야 빠지지 않습니다.
    public static let calmBlinkDuration = 0.34
    /// 말풍선이 톡 튀어나오는 시간 (Overlay: 0.18초) + 여유
    static let bubblePopTime = 0.3
    /// 머리 위 아이콘이 나타나는 시간 (Overlay: 0.2초) + 여유
    static let emoteAppearTime = 0.3

    /// 무대의 움직임 정도
    public enum Motion: Int, Comparable, Sendable {
        /// 쉬는 중 (숨쉬기·깜빡임·Zz 등 느리고 작은 움직임뿐)
        case still
        /// 일하는 중 (타이핑·손 들기)
        case busy
        /// 걷기·제스처·말풍선 톡·머리 위 아이콘 나타남·효과
        case fast

        public static func < (lhs: Motion, rhs: Motion) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// 무대의 움직임 정도
    public static func motion(_ stage: Stage) -> Motion {
        if !stage.effects.isEmpty { return .fast }
        let time = stage.time
        var motion = Motion.still
        for actor in stage.actors.values {
            if actor.isWalking || actor.gesture != nil { return .fast }
            if actor.bubble != nil, time - actor.bubbleShownAt < bubblePopTime { return .fast }
            if actor.emote != nil, time - actor.emoteShownAt < emoteAppearTime { return .fast }
            if isFastPose(actor.pose) { motion = .busy }
        }
        return motion
    }

    /// 무대에 움직임(일하는 중 이상)이 있는지
    public static func isLively(_ stage: Stage) -> Bool {
        motion(stage) != .still
    }

    /// 빠르게 반복하는 자세: 타이핑(손 22rad/s), 손 들기(5.7rad/s, 승인 대기에서 흔듦).
    /// 안마(몸 38rad/s 미세 진동 0.7pt)는 쉬는 중 몇 분씩 이어지므로 잔잔함으로 칩니다 (낮은 빈도에서도 떨림으로 보임).
    public static func isFastPose(_ pose: Pose) -> Bool {
        switch pose {
        case .typing, .raisingHand: true
        default: false
        }
    }

    /// 장면 하나의 빈도
    /// - Parameters:
    ///   - visible: 창이 화면에 보이는지 (보임·최소화 아님·가려지지 않음)
    ///   - motion: `motion(stage)`
    ///   - settling: 연출 지시를 받은 지 `settleTime`이 안 지났는지
    ///   - quietFor: 마지막으로 움직임이 있었거나 연출 지시를 받은 뒤 지난 시간 (초)
    public static func pace(visible: Bool, motion: Motion, settling: Bool, quietFor: Double = 0) -> RenderPace {
        guard visible else { return .paused }
        if motion == .fast || settling { return .active }
        if motion == .busy { return .working }
        return quietFor >= calmAfter ? .calm : .ambient
    }

    /// 모델 타이머(무대 시간 흘리기) 간격: 보이는 장면 중 가장 빠른 빈도에 맞춥니다.
    /// 아무것도 안 보이면 4Hz (연출 엔진 tick 0.25초). 잔잔함 6Hz, 잠잠함 3Hz (그리는 장마다 무대를 흘려 숨쉬기 간격이 고르게).
    public static func tickInterval(for paces: [RenderPace]) -> Double {
        let fps = paces.map(\.framesPerSecond).max() ?? 0
        return fps > 0 ? 1 / Double(fps) : hiddenTickInterval
    }

    public static let hiddenTickInterval = 0.25

    /// 무대 시간을 `dt`만큼 흘릴 때 나눠 흘릴 조각 (한 조각 최대 0.1초, 합은 최대 0.5초).
    /// 타이머가 느려져도(4Hz) 걷기·대기 시간이 실제 시간과 맞고, 앱이 오래 멈췄다 깨어나도 한꺼번에 튀지 않습니다.
    public static func steps(dt: Double, maxStep: Double = 0.1, maxTotal: Double = 0.5) -> [Double] {
        var remaining = min(max(dt, 0), maxTotal)
        var steps: [Double] = []
        while remaining > 1e-9 {
            let step = min(remaining, maxStep)
            steps.append(step)
            remaining -= step
        }
        return steps
    }
}
