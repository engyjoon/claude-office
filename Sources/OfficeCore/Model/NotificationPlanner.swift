import Foundation

/// 알림 설정 (설계서 §10 알림, M5(3)). 승인 대기는 기본으로 켜고, 응답 완료(Stop)는 기본으로 끕니다.
public struct NotificationSettings: Hashable, Sendable {
    /// 누군가 권한 승인을 기다리기 시작하면 알림
    public var permission: Bool
    /// 세션 응답이 끝나면(Stop) 알림
    public var completion: Bool
    /// 응답이 질문·결정 요청으로 끝나 내 답을 기다리기 시작하면 알림 (M6(4c), `SessionCue.reply`)
    public var reply: Bool

    public init(permission: Bool = true, completion: Bool = false, reply: Bool = true) {
        self.permission = permission
        self.completion = completion
        self.reply = reply
    }
}

/// macOS 알림 하나 (앱의 `Notifier`가 `UNNotificationRequest`로 바꿉니다)
public struct OfficeNotice: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case permission, completion
        /// 응답을 끝내고 내 답을 기다림 (M6(4c))
        case reply
    }

    /// 알림 식별자. 같은 대기·같은 세션의 알림은 같은 식별자라 알림 센터에서 서로 바꿔 끼우고 지울 수 있습니다.
    public let id: String
    public let kind: Kind
    /// "메인1 승인 대기", "서브2 응답 완료". 맨 앞 낱말이 그 사람의 직함입니다 (직함이 바뀌면 이것만 바꿔 다시 보냄, M6(14))
    public var title: String
    /// 디렉토리 이름 ("claude-office")
    public let subtitle: String
    /// "Bash npm test · 승인이 필요해요" (요약·비공개: "Bash · 승인이 필요해요")
    public let body: String
    public let agent: AgentID
    public let session: SessionID
    /// `TERM_PROGRAM` (CLI 세션의 터미널)
    public let term: String?
    /// Claude 데스크톱 앱 세션 id (`local_…`). 있으면 알림을 눌렀을 때 데스크톱 앱을 앞으로 가져옵니다.
    public let hostSession: String?
    /// 이미 띄운 알림의 내용만 보강 (소리·배너 없이 조용히 바꿈)
    public var isUpdate: Bool
    /// 알림 센터에 아직 남아 있을 때만 바꿈 (사용자가 지운 알림을 되살리지 않게). 직함이 바뀐 알림에 씁니다 (M6(14))
    public var onlyIfDelivered: Bool = false
}

public enum NoticeAction: Hashable, Sendable {
    case post(OfficeNotice)
    /// 알림 센터에서 지울 알림 식별자
    case remove([String])
}

/// 언제 알림을 띄우고 지울지, 어떤 문구를 쓸지 정하는 순수 로직 (설계서 §10 알림, M5(3)).
///
/// - 승인 대기: 리듀서가 `permissionAsked` 비트를 낼 때(대기가 시작될 때) 한 번만 띄웁니다. 같은 대기 중에 다시 오는
///   훅(Notification + PermissionRequest)은 리듀서가 이미 비트 하나로 합칩니다. Notification이 먼저 와서 도구를 몰랐다가
///   PermissionRequest로 도구를 알게 되면 같은 식별자로 내용만 조용히 바꿉니다.
/// - 대기가 풀리면(승인 뒤 도구가 끝남, 거부, 새 요청, 응답 끝, 퇴근) 그 알림을 알림 센터에서 지웁니다.
/// - 답변 필요 (M6(4c)): 응답을 끝낸 세션이 내 답을 기다리기 시작하면(`Beat.cueChanged`, `SessionCue.reply`) 응답마다 한 번.
///   마지막 문장 판정 뒤 데스크톱 앱 요약이 와서 판정이 바뀌었다 돌아와도 같은 응답이면 다시 띄우지 않습니다. 데스크톱 앱에서 그 세션을
///   보고 있거나 질문 도구의 승인 대기 알림이 떠 있으면 띄우지 않고, 답하거나(새 요청) 퇴근하거나 답변 필요가 풀리면 지웁니다.
///   이 응답에는 응답 완료 알림을 따로 띄우지 않습니다. 기본으로 켭니다.
/// - 응답 완료(Stop): 설정에서 켰을 때만. 세션마다 식별자가 하나라 새 완료 알림이 이전 것을 바꿉니다.
///   그 세션에 새 요청이 오거나 세션이 끝나면 지웁니다.
/// - 표시 수준(§7.4): 상세가 아니면 파일명·명령을 숨기고 도구 종류만 씁니다 (현황 줄과 같은 규칙).
/// - 직함이 바뀌면 (M6(14): 빈 책상으로 옮겨 앉아 서브 번호가 바뀜, 승진, "서브" ↔ "서브1") 띄워 둔 그 사람의 알림 제목도
///   같은 식별자로 조용히 바꿉니다. 알림 센터에 남아 있을 때만 바꿔(`onlyIfDelivered`) 명패와 알림의 이름이 늘 같습니다.
public struct NotificationPlanner: Sendable {
    public var settings: NotificationSettings

    struct Episode: Hashable, Sendable {
        var id: String
        var call: ToolCall?
    }

    /// 알림을 띄운 승인 대기 (사람마다 하나)
    private(set) var waiting: [AgentID: Episode] = [:]
    /// 띄운 응답 완료 알림 (세션마다 하나)
    private(set) var completions: [SessionID: String] = [:]
    /// 띄운 답변 필요 알림 (세션마다 하나)
    private(set) var replies: [SessionID: String] = [:]
    /// 답변 필요 알림을 이미 판단한 응답 (세션 → 그 응답이 끝난 때). 같은 응답이면 판정이 바뀌었다 돌아와도
    /// (마지막 문장 → 데스크톱 앱 요약) 다시 띄우지 않습니다.
    private(set) var repliedTurns: [SessionID: Date] = [:]
    /// 띄워 두고 아직 지우지 않은 알림 (식별자 → 마지막으로 보낸 알림). 직함이 바뀌면 제목을 고쳐 다시 보냅니다 (M6(14))
    private(set) var shown: [String: OfficeNotice] = [:]
    private var serial = 0

    public init(settings: NotificationSettings = .init()) {
        self.settings = settings
    }

    /// 알림을 띄운 채 아직 풀리지 않은 승인 대기 수
    public var openPermissionCount: Int { waiting.count }

    public mutating func plan(_ beats: [Beat], state: OfficeState, privacy: PrivacyLevel) -> [NoticeAction] {
        var actions: [NoticeAction] = []
        for beat in beats {
            switch beat {
            case .permissionAsked(let agent, let call):
                guard settings.permission, waiting[agent.id] == nil else { continue }
                serial += 1
                let id = "permission.\(agent.id.raw).\(serial)"
                waiting[agent.id] = Episode(id: id, call: call)
                actions.append(.post(Self.permissionNotice(id: id, agent: agent, call: call, state: state, privacy: privacy, isUpdate: false)))

            case .turnEnded(let agent, let failed):
                guard settings.completion, agent.role == .lead else { continue }
                // 답변 필요 알림을 띄울 응답이면 응답 완료 알림은 띄우지 않습니다 (둘이 겹치지 않게)
                if settings.reply, state.agents[agent.id]?.cue == .reply { continue }
                let id = "completion.\(agent.session.raw)"
                completions[agent.session] = id
                actions.append(.post(Self.completionNotice(id: id, agent: agent, failed: failed, state: state, privacy: privacy)))

            case .promptArrived(let agent):
                if let id = completions.removeValue(forKey: agent.session) { actions.append(.remove([id])) }

            case .left(let agent) where agent.role == .lead:
                if let id = completions.removeValue(forKey: agent.session) { actions.append(.remove([id])) }
                if let id = replies.removeValue(forKey: agent.session) { actions.append(.remove([id])) }
                repliedTurns[agent.session] = nil

            case .cueChanged(let agent):
                planReply(agent, state: state, privacy: privacy, into: &actions)

            default:
                continue
            }
        }

        // 풀린 대기는 지우고, 나중에 도구를 알게 된 대기는 내용만 보강합니다
        var cleared: [String] = []
        for (agentID, episode) in waiting.sorted(by: { $0.key < $1.key }) {
            guard let agent = state.agents[agentID], case .waitingForPermission(let call) = agent.activity else {
                waiting[agentID] = nil
                cleared.append(episode.id)
                continue
            }
            if episode.call == nil, let call {
                waiting[agentID]?.call = call
                actions.append(.post(Self.permissionNotice(
                    id: episode.id, agent: agent, call: call, state: state, privacy: privacy, isUpdate: true)))
            }
        }
        if !cleared.isEmpty { actions.append(.remove(cleared)) }
        retitle(state: state, actions: &actions)
        return actions
    }

    /// 보낸·지운 알림을 기억하고, 띄워 둔 알림 중 그 사람의 직함이 바뀐 것은 제목만 고쳐 조용히 다시 보냅니다 (M6(14)).
    private mutating func retitle(state: OfficeState, actions: inout [NoticeAction]) {
        for action in actions {
            switch action {
            case .post(let notice): shown[notice.id] = notice
            case .remove(let ids): for id in ids { shown[id] = nil }
            }
        }
        for (id, notice) in shown.sorted(by: { $0.key < $1.key }) {
            guard let agent = state.agents[notice.agent],
                let renamed = Self.retitled(notice, as: agent.title.label)
            else { continue }
            shown[id] = renamed
            actions.append(.post(renamed))
        }
    }

    /// 제목의 맨 앞 직함을 바꾼 알림. 이미 그 직함이면 nil
    static func retitled(_ notice: OfficeNotice, as label: String) -> OfficeNotice? {
        let parts = notice.title.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard let head = parts.first, head != label[...] else { return nil }
        var renamed = notice
        renamed.title = parts.count > 1 ? "\(label) \(parts[1])" : label
        renamed.isUpdate = true
        renamed.onlyIfDelivered = true
        return renamed
    }

    /// 답변 필요 (M6(4c)): 응답마다 한 번. 질문 도구의 승인 대기 알림이 떠 있거나, 사용자가 데스크톱 앱에서 그 세션을
    /// 보고 있으면 띄우지 않습니다(그 응답은 판단한 것으로 칩니다). 답하거나(새 요청) 답변 필요가 풀리면 지웁니다.
    private mutating func planReply(_ agent: Agent, state: OfficeState, privacy: PrivacyLevel, into actions: inout [NoticeAction]) {
        let session = agent.session
        guard agent.cue == .reply else {
            if let id = replies.removeValue(forKey: session) { actions.append(.remove([id])) }
            return
        }
        guard settings.reply, let turn = state.parts[session]?.completedAt, repliedTurns[session] != turn else { return }
        repliedTurns[session] = turn
        guard waiting[agent.id] == nil, !state.isViewing(session) else { return }
        if let id = completions.removeValue(forKey: session) { actions.append(.remove([id])) }
        let id = "reply.\(session.raw)"
        replies[session] = id
        actions.append(.post(Self.replyNotice(id: id, agent: agent, state: state, privacy: privacy)))
    }

    // MARK: - 문구

    static func permissionNotice(
        id: String, agent: Agent, call: ToolCall?, state: OfficeState, privacy: PrivacyLevel, isUpdate: Bool
    ) -> OfficeNotice {
        let words = StatusLine.Words(state: state, privacy: privacy)
        if let call, call.asksUser {
            // 질문·계획 승인 (M5(4)): "메인1 질문 답 대기" / "질문에 답해 주세요"
            return notice(
                id: id, kind: .permission, title: "\(agent.title.label) \(call.waitLabel)", body: call.waitRequest, agent: agent, state: state,
                isUpdate: isUpdate)
        }
        let body = call.map { "\(words.toolText($0)) · 승인이 필요해요" } ?? "승인이 필요해요"
        return notice(id: id, kind: .permission, title: "\(agent.title.label) 승인 대기", body: body, agent: agent, state: state, isUpdate: isUpdate)
    }

    static func completionNotice(id: String, agent: Agent, failed: Bool, state: OfficeState, privacy: PrivacyLevel) -> OfficeNotice {
        // 세션 제목은 신원 카드·세션 목록처럼 상세일 때만
        let sessionTitle = privacy == .detailed ? state.parts[agent.session]?.title.flatMap { $0.isEmpty ? nil : $0 } : nil
        let body = failed ? "오류로 응답이 멈췄어요" : (sessionTitle.map { "\($0) · 응답을 마쳤어요" } ?? "응답을 마쳤어요")
        return notice(
            id: id, kind: .completion, title: "\(agent.title.label) \(failed ? "응답 중단" : "응답 완료")", body: body, agent: agent,
            state: state, isUpdate: false)
    }

    static func replyNotice(id: String, agent: Agent, state: OfficeState, privacy: PrivacyLevel) -> OfficeNotice {
        let sessionTitle = privacy == .detailed ? state.parts[agent.session]?.title.flatMap { $0.isEmpty ? nil : $0 } : nil
        let body = sessionTitle.map { "\($0) · 답을 기다려요" } ?? "응답을 마치고 답을 기다려요"
        return notice(
            id: id, kind: .reply, title: "\(agent.title.label) 답변 대기", body: body, agent: agent, state: state, isUpdate: false)
    }

    private static func notice(
        id: String, kind: OfficeNotice.Kind, title: String, body: String, agent: Agent, state: OfficeState, isUpdate: Bool
    ) -> OfficeNotice {
        let part = state.parts[agent.session]
        let folder = state.teams[agent.teamID]?.name ?? part.flatMap { state.teams[$0.teamID]?.name } ?? ""
        return OfficeNotice(
            id: id, kind: kind, title: title, subtitle: folder, body: body, agent: agent.id, session: agent.session,
            term: agent.term, hostSession: part?.hostSession, isUpdate: isUpdate)
    }
}
