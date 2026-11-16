import Foundation
import OfficeCore

/// 한 순간의 리그 자세. 렌더러는 정적인 부위 도형에 이 값만 적용합니다.
/// 각도는 y가 아래로 증가하는 좌표계 기준 시계 방향(도)입니다. SpriteKit에서는 부호를 뒤집습니다.
public struct RigPose: Hashable, Sendable {
    /// 몸 전체 위아래 (음수 = 위로)
    public var bob: Double = 0
    public var leftLegLift: Double = 0
    public var rightLegLift: Double = 0
    public var headRotation: Double = 0
    public var headDrop: Double = 0
    public var leftArm: Double = 12
    public var rightArm: Double = -12
    /// 눈 세로 배율 (깜빡임 0.12)
    public var eyeScale: Double = 1
    /// 몸 세로 늘이기 (기지개)
    public var stretch: Double = 1
    public var mirrored = false

    public init() {}
}

/// 직원 상태와 무대 시각으로 리그 자세를 계산합니다 (미리보기의 CSS 애니메이션을 옮긴 것).
public enum RigAnimator {
    /// - Parameter blinkDuration: 깜빡임 길이 (초). 그리기 빈도가 낮을 때(잠잠함 3fps) 늘려서 깜빡임이 빠지지 않게 합니다 (M6(1)).
    public static func pose(for actor: StageActor, time: Double, blinkDuration: Double = 0.14) -> RigPose {
        var pose = RigPose()
        let seed = Double(StableHashLite.value(actor.id.raw) % 997) / 997 * 4.6
        let base = armAngles(actor.pose)
        pose.leftArm = base.0
        pose.rightArm = base.1
        pose.mirrored = actor.facing == .left

        if actor.isWalking {
            let phase = actor.walkedDistance / 14 * Double.pi
            pose.leftLegLift = -max(0, sin(phase)) * 2.6
            pose.rightLegLift = -max(0, -sin(phase)) * 2.6
            pose.bob = -abs(sin(phase)) * 1.4
            pose.leftArm = 8 + sin(phase) * 13
            pose.rightArm = -8 + sin(phase) * 13
        } else {
            // 숨쉬기
            pose.bob = -1.3 * (sin(time * 2 * Double.pi / 2.8) + 1) / 2
            switch actor.pose {
            case .typing:
                pose.leftArm += 4.5 * sin(time * 22)
                pose.rightArm += 4.5 * sin(time * 22 + 1.6)
            case .raisingHand:
                let wave = (1 + sin(time * 5.7)) / 2
                pose.rightArm = -146 - 14 * wave
                pose.bob = -2.5 * wave
            case .thinking:
                pose.headRotation = -6
            case .sleeping:
                pose.headRotation = 8 + 2.5 * sin(time * 2.1)
                pose.headDrop = 2 + sin(time * 2.1)
            case .holdingCup:
                pose.rightArm = sipAngle(time)
            case .watching:
                // 모니터를 보며 기다림: 손은 책상 위, 고개를 천천히 갸웃하다 가끔 콕 끄덕
                pose.headRotation = 3 * sin(time * 1.4 + seed)
                let tap = (time + seed).truncatingRemainder(dividingBy: 2.2)
                pose.headDrop = tap < 0.25 ? 1.6 * sin(tap / 0.25 * Double.pi) : 0
            case .massage:
                // 안마받는 중: 몸이 잘게 떨리고 고개는 느리게 흔들림, 팔은 팔걸이에
                pose.bob = -0.7 * (1 + sin(time * 38)) / 2
                pose.headRotation = 6 * sin(time * 1.2 + seed)
            default:
                break
            }
        }

        if let gesture = actor.gesture {
            apply(gesture, elapsed: time - actor.gestureStartedAt, to: &pose)
        }

        // 깜빡임 (직원마다 엇갈리게)
        if CharacterArt.blinks(actor.expression) {
            let cycle = (time + seed).truncatingRemainder(dividingBy: 4.6)
            if cycle > 4.5 - blinkDuration && cycle < 4.5 { pose.eyeScale = 0.12 }
        }
        return pose
    }

    public static func armAngles(_ pose: Pose) -> (Double, Double) {
        switch pose {
        case .typing: (-38, 38)
        case .reading, .sorting, .sleeping: (-34, 34)
        case .watching: (-30, 30)
        case .massage: (30, -30)
        case .thinking: (12, 125)
        case .writingBoard: (12, -110)
        case .holdingCup: (12, 95)
        case .raisingHand: (12, -152)
        case .standing, .sitting: (12, -12)
        }
    }

    static func sipAngle(_ time: Double) -> Double {
        let t = time.truncatingRemainder(dividingBy: 3.4) / 3.4
        switch t {
        case ..<0.3: return 95
        case ..<0.45: return 95 + (t - 0.3) / 0.15 * 43
        case ..<0.7: return 138
        case ..<0.85: return 138 - (t - 0.7) / 0.15 * 43
        default: return 95
        }
    }

    static func apply(_ gesture: BodyGesture, elapsed t: Double, to pose: inout RigPose) {
        switch gesture {
        case .wave: pose.rightArm = -142.5 + 17.5 * sin(t * 12.5)
        case .nod: pose.headDrop = 2.5 * max(0, sin(t * 8))
        case .beckon: pose.rightArm = -111 + 16 * sin(t * 14)
        case .thumbsUp: pose.rightArm = -95
        case .cheer:
            pose.leftArm = 151 + 11 * sin(t * 20)
            pose.rightArm = -151 - 11 * sin(t * 20)
            pose.bob = -3.5 * (1 + sin(t * 10))
        case .highFive:
            pose.rightArm = -140
            pose.bob = -1.25 * (1 + sin(t * 7.8))
        case .tilt: pose.headRotation = 13 * sin(min(t, 0.6) / 0.6 * Double.pi / 2)
        case .scratchHead:
            pose.rightArm = -168 + 5 * sin(t * 28)
            pose.headRotation = 7
        case .stretch:
            pose.leftArm = 166
            pose.rightArm = -166
            pose.stretch = 1 + 0.05 * sin(min(t, 1.2) / 1.2 * Double.pi)
        case .sip: pose.rightArm = 138
        }
    }
}

/// 리그용 가벼운 해시 (직원마다 깜빡임 시점을 엇갈리게)
enum StableHashLite {
    static func value(_ text: String) -> Int {
        var hash = 5381
        for byte in text.utf8 { hash = (hash &* 33) ^ Int(byte) }
        return nonNegative(hash)
    }

    /// 절댓값. `abs(Int.min)`은 넘쳐서 죽으므로 그 값만 0으로 둡니다 (나머지는 `abs`와 같은 값)
    static func nonNegative(_ hash: Int) -> Int {
        hash == .min ? 0 : abs(hash)
    }
}
