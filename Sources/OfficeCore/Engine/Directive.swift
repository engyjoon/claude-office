import Foundation

/// 사무실 안의 장소 (설계서 §8.1). 실제 좌표는 씬이 맵에서 정합니다.
public enum Spot: Hashable, Sendable, CustomStringConvertible {
    case door
    /// 행 안의 자기 책상 (0번 = 메인)
    case seat(TeamID, Seat)
    /// 특정 직원 바로 옆 (위임·보고 대화용)
    case beside(AgentID)
    case whiteboard
    /// 휴게 공간 (3인용 소파 둘)
    case lounge
    /// 휴게 공간의 안마 의자 (2개)
    case massageChair
    /// 탕비 코너 (냉장고·정수기)
    case pantry

    public var isSeat: Bool {
        if case .seat = self { return true }
        return false
    }

    public var description: String {
        switch self {
        case .door: "문"
        case .seat(let team, let seat): "자리(\(team.raw.split(separator: "/").last ?? "")#\(seat))"
        case .beside(let agent): "\(agent) 옆"
        case .whiteboard: "화이트보드"
        case .lounge: "휴게 공간"
        case .massageChair: "안마 의자"
        case .pantry: "탕비 코너"
        }
    }
}

/// 계속 유지되는 자세
public enum Pose: String, Hashable, Sendable {
    case standing, sitting, typing, reading, thinking, writingBoard, holdingCup, raisingHand, sleeping, sorting
    /// 오래 걸리는 셸 명령을 자기 책상에서 모니터를 보며 기다림 (M4.5b, 서버랙 대신)
    case watching
    /// 안마 의자에 앉아 안마받기: 몸 미세 진동, 느린 고개 흔들림, 팔은 팔걸이
    case massage
}

/// 한 번 하고 끝나는 동작 (설계서 §9.3 제스처 12종 중 상황 연출에 쓰는 것)
public enum BodyGesture: String, Hashable, Sendable {
    case wave, nod, beckon, thumbsUp, cheer, highFive, tilt, scratchHead, stretch, sip
}

/// 표정 10종 (설계서 §9.3)
public enum FacialExpression: String, Hashable, Sendable {
    case neutral, happy, focus, think, surprised, troubled, sleepy, proud, sad, eager
}

/// 머리 위 아이콘
public enum Emote: String, Hashable, Sendable {
    case exclamation, question, bulb, sweat, sparkle, zzz, note
    /// 오래 걸리는 명령을 기다리는 중 ⏳
    case hourglass
}

public enum BubbleKind: String, Hashable, Sendable {
    case speech, thought, shout, whisper
}

public struct Bubble: Hashable, Sendable {
    public var kind: BubbleKind
    public var text: String
    /// 표시 시간(초). nil이면 `dismissBubble`이 올 때까지 유지합니다 (승인 대기 외침 풍선).
    public var duration: Double?

    public init(kind: BubbleKind, text: String, duration: Double?) {
        self.kind = kind
        self.text = text
        self.duration = duration
    }

    /// 설계서 §7.2: 1.8초 + 글자당 60ms, 최대 6초
    public static func timed(_ kind: BubbleKind, _ text: String) -> Bubble {
        Bubble(kind: kind, text: text, duration: min(6, 1.8 + 0.06 * Double(text.count)))
    }
}

/// 머리 위 상태 칩 ("Edit · auth.ts")
public struct StatusPill: Hashable, Sendable {
    public var category: ToolCategory
    public var text: String
    /// 요약 수준에서 보일 말: 보통 종류 이름("파일 읽는 중"), MCP는 "브라우저 사용 중"·"할 일 목록 정리" (M6(5)).
    /// 설정을 요약으로 바꾸면 화면(Overlay)이 칩을 다시 받지 않고 이 말로 바꿔 그립니다.
    public var summary: String

    public init(category: ToolCategory, text: String, summary: String? = nil) {
        self.category = category
        self.text = text
        self.summary = summary ?? category.summaryLabel
    }
}

public enum Prop: String, Hashable, Sendable {
    case book, cup, documents, marker
    /// 탕비 코너 냉장고에서 꺼낸 음료
    case drink
}

public enum Effect: Hashable, Sendable {
    /// 새 프롬프트가 종이비행기로 날아와 세션 직원에게 도착
    case paperPlane(to: AgentID)
}

/// 연출 엔진이 씬에 내리는 지시.
///
/// 씬은 직원마다 대기열을 하나씩 두고 지시를 **순서대로** 실행합니다.
/// - `walk`는 도착할 때까지, `wait`는 그 시간만큼 다음 지시를 막습니다.
/// - `signal`/`await`로 두 직원의 대기열을 맞춥니다 (보고하러 온 서브에이전트가 도착한 뒤 부른 사람이 하이파이브).
/// - `clearQueue`는 아직 실행하지 않은 지시를 버립니다 (승인 대기처럼 급한 일).
/// - `agent`가 nil인 지시(팀 열기·닫기, 효과, 전역 효과음)는 즉시 실행합니다.
public struct Directive: Hashable, Sendable, CustomStringConvertible {
    public enum Action: Hashable, Sendable {
        case openTeam(Team)
        /// 사람이 모두 떠난 방을 닫습니다. 씬은 남은 직원이 문을 나간 뒤 섬을 비웁니다.
        case closeTeam(TeamID)
        case spawn(Agent, at: Spot)
        /// 직원 정보(직함·좌석)를 새로 고칩니다. 명패도 바뀝니다.
        case refresh(Agent)
        case despawn
        case clearQueue
        case walk(to: Spot)
        case sit
        case stand
        case pose(Pose)
        case gesture(BodyGesture)
        case express(FacialExpression)
        case emote(Emote?)
        /// 머리 왼쪽 위 배지 (답변 필요 "?", 확인 안 함 ✉, M6(4)). 쉼 단계와 상관없이 따라다닙니다.
        case badge(SessionCue?)
        case say(Bubble)
        case dismissBubble
        case status(StatusPill?)
        case prop(Prop?)
        case wait(Double)
        case signal(String)
        case await(String, timeout: Double)
        case effect(Effect)
        case sound(SoundCue)
    }

    public var agent: AgentID?
    public var action: Action

    public init(_ agent: AgentID?, _ action: Action) {
        self.agent = agent
        self.action = action
    }

    public var description: String {
        let who = agent.map { "\($0)" } ?? "*"
        let what: String
        switch action {
        case .openTeam(let team): what = "팀 열기 \(team.name) (방 \(team.island))"
        case .closeTeam(let team): what = "팀 닫기 \(team.raw.split(separator: "/").last ?? "")"
        case .spawn(let agent, let spot): what = "등장 \(agent.displayName) @\(spot)"
        case .refresh(let agent): what = "정보 갱신 \(agent.displayName) (자리 \(agent.seat))"
        case .despawn: what = "퇴장"
        case .clearQueue: what = "대기열 비우기"
        case .walk(let spot): what = "걷기 → \(spot)"
        case .sit: what = "앉기"
        case .stand: what = "일어서기"
        case .pose(let pose): what = "자세 \(pose.rawValue)"
        case .gesture(let gesture): what = "제스처 \(gesture.rawValue)"
        case .express(let expression): what = "표정 \(expression.rawValue)"
        case .emote(let emote): what = "아이콘 \(emote?.rawValue ?? "없음")"
        case .badge(let cue): what = "배지 \(cue?.rawValue ?? "없음")"
        case .say(let bubble): what = "말풍선[\(bubble.kind.rawValue)] \"\(bubble.text)\""
        case .dismissBubble: what = "말풍선 닫기"
        case .status(let pill): what = "상태 칩 \(pill.map { "\"\($0.text)\"" } ?? "없음")"
        case .prop(let prop): what = "소품 \(prop?.rawValue ?? "없음")"
        case .wait(let seconds): what = "대기 \(seconds)초"
        case .signal(let name): what = "신호 \(name)"
        case .await(let name, let timeout): what = "신호 기다림 \(name) (최대 \(timeout)초)"
        case .effect(let effect): what = "효과 \(effect)"
        case .sound(let cue): what = "효과음 \(cue)"
        }
        return "\(who): \(what)"
    }
}
