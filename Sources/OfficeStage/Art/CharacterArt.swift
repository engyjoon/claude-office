import Foundation
import OfficeCore

/// 종이인형 리그 캐릭터 그림 (설계서 §9.3, 미리보기의 character()를 옮긴 것).
/// 좌표는 발 위치가 원점이고 y가 아래로 증가합니다.
public enum CharacterArt {
    // MARK: - 색

    public static let skins: [UInt32] = [0xFBDDC8, 0xF3C6A5, 0xD9A47F, 0xB07A5C]
    public static let hairs: [UInt32] = [0x3B2F3A, 0x6B4A3A, 0xA86B4C, 0xE2B866, 0x5A5F8C, 0x8A5A6A, 0x2F2A33, 0x5A4256]
    public static let tops: [UInt32] = [0x9FD8C7, 0xF6B9A0, 0xC7BCEB, 0xF7DE8B, 0xA9D3F0, 0xF4A3B4]
    public static let pants: [UInt32] = [0x5D5670, 0x4F5A7A, 0x46506E]

    public struct Colors: Hashable, Sendable {
        public var skin: ArtColor
        public var hair: ArtColor
        public var top: ArtColor
        public var pants: ArtColor
    }

    public static func colors(for appearance: Appearance) -> Colors {
        Colors(
            skin: ArtColor(skins[abs(appearance.skinTone) % skins.count]),
            hair: ArtColor(hairs[abs(appearance.hairColor) % hairs.count]),
            top: ArtColor(tops[abs(appearance.topColor) % tops.count]),
            pants: ArtColor(pants[abs(appearance.hairColor + appearance.topColor) % pants.count])
        )
    }

    // MARK: - 부위 위치

    public static let headOrigin = MapPoint(0, -62)
    public static let leftShoulder = MapPoint(-14, -38)
    public static let rightShoulder = MapPoint(14, -38)
    public static let heldPropOrigin = MapPoint(0, -28)

    // MARK: - 몸

    public static let shadow: [ArtShape] = [.ellipse(0, 0, 17, 4.5, fill: .swatch(.shadow))]

    public static let leftLeg: [ArtShape] = [.rect(-10, -17, 8.5, 17, r: 4, fill: .pants)]
    public static let rightLeg: [ArtShape] = [.rect(1.5, -17, 8.5, 17, r: 4, fill: .pants)]

    public static func body(isLead: Bool) -> [ArtShape] {
        var shapes: [ArtShape] = [.rect(-15, -44, 30, 30, r: 12, fill: .top)]
        if isLead {
            shapes.append(ArtShape(.path(star5(MapPoint(7, -31), 4.6)), fill: .swatch(.butter), stroke: .swatch(.ink), lineWidth: 1.3))
        }
        return shapes
    }

    /// 어깨가 원점, 아래로 늘어진 팔 (회전은 렌더러가 적용)
    public static let arm: [ArtShape] = [
        .rect(-3.6, -2, 7.2, 17, r: 3.6, fill: .top),
        .circle(0, 16, 4.2, fill: .skin),
    ]

    /// 오른손에 드는 소품 (팔과 함께 회전)
    public static func handProp(_ prop: Prop?) -> [ArtShape] {
        switch prop {
        case .cup:
            return [.rect(-4.5, 11, 9, 9, r: 2, fill: .swatch(.white)), .line("M4.5,13 q4,1 0,5", width: 1.4)]
        case .marker:
            return [.rect(-1.6, 12, 3.2, 12, r: 1.2, fill: .swatch(.alert), width: 1)]
        default:
            return []
        }
    }

    /// 몸 앞에 드는 소품 (원점: heldPropOrigin)
    public static func heldProp(_ prop: Prop?) -> [ArtShape] {
        switch prop {
        case .book:
            return [
                .rect(-12, -7.5, 24, 15, r: 2, fill: .swatch(.lavender)),
                .rect(-10, -5.5, 20, 11, r: 1, fill: .swatch(.white), outline: false),
                .line("M0,-5.5 L0,5.5 M-8,-2.5 L-3,-2.5 M-8,0.5 L-3,0.5 M3,-2.5 L8,-2.5 M3,0.5 L7,0.5", width: 1.1),
            ]
        case .documents:
            return [
                .rect(-12, -6, 22, 14, r: 1.5, fill: .swatch(.white), width: 1.2),
                .rect(-9, -9, 22, 14, r: 1.5, fill: .swatch(.white), width: 1.2),
                .line("M-6,-5 L8,-5 M-6,-2 L6,-2 M-6,1 L8,1", width: 1),
            ]
        default:
            return []
        }
    }

    // MARK: - 머리 (원점: headOrigin)

    public static let face: [ArtShape] = [.circle(0, 0, 21, fill: .skin)]

    public static func blush(_ expression: FacialExpression) -> [ArtShape] {
        let opacity = [.happy, .proud, .eager].contains(expression) ? 0.72 : 0.45
        return [
            .ellipse(-13, 7, 3.8, 2.4, fill: .swatch(.blush), opacity: opacity),
            .ellipse(13, 7, 3.8, 2.4, fill: .swatch(.blush), opacity: opacity),
        ]
    }

    public static func hairBack(style: Int) -> [ArtShape] {
        switch abs(style) % 5 {
        case 0: [bobBack]
        case 1: [shortBack]
        case 2: [.path("M-24,2 C-26,-23 -12,-27 0,-27 C12,-27 26,-23 24,2 L26,30 C18,34 -18,34 -26,30 Z", fill: .hair)]
        case 3: [.circle(0, -27, 8.5, fill: .hair), shortBack]
        default: [shortBack]
        }
    }

    public static func hairFront(style: Int) -> [ArtShape] {
        switch abs(style) % 5 {
        case 0, 3: [bobFront]
        case 1: [.path("M-21.5,-2 C-22.5,-18 -11,-25 0,-25 C11,-25 22.5,-18 21.5,-2 L17,-9 L13,-5 L10,-12 L5,-7 L1,-13 L-4,-8 L-8,-13 L-12,-7 L-16,-10 Z", fill: .hair)]
        default: [sweptFront]
        }
    }

    static let bobBack = ArtShape.path("M-24,6 C-26,-22 -12,-27 0,-27 C12,-27 26,-22 24,6 C24,12 20,15 16,15 L-16,15 C-20,15 -24,12 -24,6 Z", fill: .hair)
    static let shortBack = ArtShape.circle(0, -3, 22.5, fill: .hair)
    static let bobFront = ArtShape.path("M-21.5,-3 C-22,-19 -11,-24.5 0,-24.5 C11,-24.5 22,-19 21.5,-3 C17,-9 11,-11.5 5,-9.5 C1,-14 -9,-14 -13,-9 C-16,-8 -19,-6 -21.5,-3 Z", fill: .hair)
    static let sweptFront = ArtShape.path("M-21.5,-1 C-22,-19 -9,-25 1,-24.5 C13,-24 22,-17 21.5,-3 C13,-5 5,-10 -1,-16 C-5,-9 -13,-4 -21.5,-1 Z", fill: .hair)

    public static func accessory(_ accessory: Accessory?) -> [ArtShape] {
        switch accessory {
        case .glasses:
            return [
                ArtShape(.circle(center: MapPoint(-8, 1.5), radius: 5.4), stroke: .swatch(.ink), lineWidth: 1.6),
                ArtShape(.circle(center: MapPoint(8, 1.5), radius: 5.4), stroke: .swatch(.ink), lineWidth: 1.6),
                .line("M-2.6,1 Q0,-0.5 2.6,1", width: 1.6),
            ]
        case .headphones:
            return [
                .line("M-23,2 C-24,-31 24,-31 23,2", width: 4, color: .color(ArtColor(0x7B6FB0))),
                .rect(-27, -4, 7, 12, r: 3, fill: .swatch(.lavender)),
                .rect(20, -4, 7, 12, r: 3, fill: .swatch(.lavender)),
            ]
        case .beanie:
            return [
                .path("M-22,-7 C-22,-31 22,-31 22,-7 Z", fill: .swatch(.peach)),
                .rect(-23, -11, 46, 7, r: 3.5, fill: .color(ArtColor(0xEE9F84))),
                .circle(0, -29, 4.5, fill: .swatch(.white)),
            ]
        case .ribbon:
            return [
                .path("M14,-19 L7.8,-26.4 L4.3,-17 Z M14,-19 L20.2,-11.6 L23.7,-21 Z", fill: .swatch(.pink)),
                .circle(14, -19, 2.2, fill: .swatch(.pink)),
            ]
        case .sprout:
            return [
                .line("M0,-24 C0,-30 1,-33 0,-36", width: 2, color: .color(ArtColor(0x5FA77F))),
                .ellipse(-5, -37, 5, 3, fill: .swatch(.mint), outline: true),
                .ellipse(5, -39, 5, 3, fill: .swatch(.mint), outline: true),
            ]
        case .none:
            return []
        }
    }

    // MARK: - 표정 (설계서 §9.3 표정 10종)

    static func dotEye(_ x: Double) -> [ArtShape] {
        [.ellipse(x, 1, 2.5, 3.1, fill: .swatch(.ink)), .circle(x + 0.9, -0.3, 0.85, fill: .swatch(.white), outline: false)]
    }

    static let worried: [ArtShape] = [.line("M-11,-5 L-5,-7.5", width: 1.6), .line("M5,-7.5 L11,-5", width: 1.6)]

    public static func eyes(_ expression: FacialExpression) -> [ArtShape] {
        switch expression {
        case .neutral, .troubled: dotEye(-8) + dotEye(8)
        case .happy: [.line("M-11,2.5 Q-8,-1.5 -5,2.5", width: 2.3), .line("M5,2.5 Q8,-1.5 11,2.5", width: 2.3)]
        case .focus: [.ellipse(-8, 2, 2.5, 2.2, fill: .swatch(.ink)), .ellipse(8, 2, 2.5, 2.2, fill: .swatch(.ink))]
        case .think: [.ellipse(-6.5, -0.5, 2.3, 2.9, fill: .swatch(.ink)), .ellipse(9.5, -0.5, 2.3, 2.9, fill: .swatch(.ink))]
        case .surprised:
            [
                .circle(-8, 1, 3.8, fill: .swatch(.white), width: 1.4), .circle(-8, 1.4, 2, fill: .swatch(.ink), outline: false),
                .circle(8, 1, 3.8, fill: .swatch(.white), width: 1.4), .circle(8, 1.4, 2, fill: .swatch(.ink), outline: false),
            ]
        case .sleepy: [.line("M-11,2 L-5,2"), .line("M5,2 L11,2")]
        case .proud: [ArtShape(.path(star4(MapPoint(-8, 1), 4)), fill: .swatch(.ink)), ArtShape(.path(star4(MapPoint(8, 1), 4)), fill: .swatch(.ink))]
        case .sad:
            [
                .ellipse(-8, 1, 2.2, 2.8, fill: .swatch(.ink)), .ellipse(8, 1, 2.2, 2.8, fill: .swatch(.ink)),
                .line("M-8,5.5 L-8,10", width: 2.2, color: .swatch(.drop)), .line("M8,5.5 L8,10", width: 2.2, color: .swatch(.drop)),
            ]
        case .eager:
            [
                .circle(-8, 1, 3.4, fill: .swatch(.ink), outline: false), .circle(-6.8, -0.3, 1.25, fill: .swatch(.white), outline: false),
                .circle(8, 1, 3.4, fill: .swatch(.ink), outline: false), .circle(9.2, -0.3, 1.25, fill: .swatch(.white), outline: false),
            ]
        }
    }

    /// 눈을 감은 표정은 깜빡이지 않습니다
    public static func blinks(_ expression: FacialExpression) -> Bool {
        ![.happy, .sleepy, .proud].contains(expression)
    }

    public static func brows(_ expression: FacialExpression) -> [ArtShape] {
        switch expression {
        case .focus: [.line("M-11.5,-0.6 L-4.5,0.2"), .line("M4.5,0.2 L11.5,-0.6"), .line("M-11,-6.5 L-5,-5", width: 1.6), .line("M5,-5 L11,-6.5", width: 1.6)]
        case .think: [.line("M-11,-6 Q-8,-8 -5,-6.5", width: 1.6), .line("M5,-8 Q8,-10 11,-8.5", width: 1.6)]
        case .surprised, .eager: [.line("M-11,-8 Q-8,-10.5 -5,-8", width: 1.6), .line("M5,-8 Q8,-10.5 11,-8", width: 1.6)]
        case .troubled, .sad: worried
        default: []
        }
    }

    public static func mouth(_ expression: FacialExpression) -> [ArtShape] {
        switch expression {
        case .neutral: [.line("M-3.5,10 Q0,13 3.5,10")]
        case .happy: [.path("M-6,8 Q0,16.5 6,8 Z", fill: .swatch(.mouth))]
        case .focus: [.line("M-3,11 L3,11")]
        case .think: [ArtShape(.circle(center: MapPoint(3, 11), radius: 1.8), stroke: .swatch(.ink), lineWidth: 1.6)]
        case .surprised: [.ellipse(0, 11.5, 2.6, 3.2, fill: .swatch(.mouth), outline: true)]
        case .troubled: [.line("M-4.5,11.5 q1.5,-2 3,0 t3,0", width: 1.7)]
        case .sleepy: [.ellipse(0, 11, 1.6, 1.2, fill: .swatch(.ink))]
        case .proud: [.path("M-6.5,8.5 Q0,16 6.5,8.5 Z", fill: .swatch(.mouth))]
        case .sad: [.line("M-3.5,13.5 Q0,10.5 3.5,13.5")]
        case .eager: [.path("M-4.5,8.5 Q0,15 4.5,8.5 Z", fill: .swatch(.mouth))]
        }
    }

    /// 표정에 딸린 효과 (땀방울, 반짝이)
    public static func effects(_ expression: FacialExpression) -> [ArtShape] {
        switch expression {
        case .troubled: [.path("M18,-14 q-4.5,6.5 0,8.5 q4.5,-2 0,-8.5 Z", fill: .swatch(.drop), width: 1.4)]
        case .proud: [ArtShape(.path(star4(MapPoint(22, -20), 5.5)), fill: .swatch(.butter), stroke: .swatch(.ink), lineWidth: 1.3)]
        default: []
        }
    }

    // MARK: - 도형 도우미

    static func star4(_ c: MapPoint, _ r: Double) -> [PathCommand] {
        [
            .move(MapPoint(c.x, c.y - r)), .quad(control: c, to: MapPoint(c.x + r, c.y)), .quad(control: c, to: MapPoint(c.x, c.y + r)),
            .quad(control: c, to: MapPoint(c.x - r, c.y)), .quad(control: c, to: MapPoint(c.x, c.y - r)), .close,
        ]
    }

    static func star5(_ c: MapPoint, _ r: Double) -> [PathCommand] {
        var commands: [PathCommand] = []
        for i in 0..<10 {
            let angle = -Double.pi / 2 + Double(i) * Double.pi / 5
            let radius = i % 2 == 1 ? r * 0.45 : r
            let point = MapPoint(c.x + radius * cos(angle), c.y + radius * sin(angle))
            commands.append(i == 0 ? .move(point) : .line(point))
        }
        commands.append(.close)
        return commands
    }
}

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
}

/// 직원 상태와 무대 시각으로 리그 자세를 계산합니다 (미리보기의 CSS 애니메이션을 옮긴 것).
public enum RigAnimator {
    public static func pose(for actor: StageActor, time: Double) -> RigPose {
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
            if cycle > 4.36 && cycle < 4.5 { pose.eyeScale = 0.12 }
        }
        return pose
    }

    public static func armAngles(_ pose: Pose) -> (Double, Double) {
        switch pose {
        case .typing: (-38, 38)
        case .reading, .sorting, .sleeping: (-34, 34)
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
        return abs(hash)
    }
}
