import Foundation

/// 직원이 한 일 하나 (실시간 현황 줄, 설계서 §10.2). 툴 하나, 승인 요청, 위임, 보고가 각각 한 줄입니다.
public struct ActivityEntry: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case tool(ToolCall)
        /// 툴 시작 없이 온 승인 요청 (Notification만 온 경우 등)
        case permission(ToolCall?)
        /// 서브에게 일을 맡김. `title`은 그때의 직함 (퇴근한 뒤에도 쓰려고)
        case delegated(member: AgentID, title: String)
        /// 맡은 일을 마치고 부른 사람에게 보고
        case reported(to: AgentID?, title: String?)
    }

    public enum State: Hashable, Sendable {
        case running
        case awaitingPermission
        case succeeded
        case failed
        case denied
        case interrupted
        /// 결과를 모른 채 닫힘 (응답이 끝났거나, 새 요청이 왔거나, 퇴근함)
        case closed

        /// 아직 진행 중인지 (경과 시간을 붙임)
        public var isOpen: Bool { self == .running || self == .awaitingPermission }
    }

    public let serial: Int
    public let agent: AgentID
    /// 기록할 때의 직함. 지금 사무실에 있으면 현황 줄은 지금 직함을 씁니다.
    public let title: String
    /// 기록할 때의 행 폴더 (디렉토리 필터용, 퇴근한 사람)
    public let folder: String?
    public let kind: Kind
    public let at: Date
    public internal(set) var state: State
    /// 지금 상태가 된 시각 (승인 대기는 요청이 온 때부터 셉니다)
    public internal(set) var since: Date
}

/// 직원별 최근 활동 기록 (설계서 §10.2). 엔진이 리듀서의 비트로 채우며, 오래된 것부터 버립니다.
/// 퇴근한 사람의 기록도 한동안 남겨 둡니다 ("서브2가 메인에게 보고").
public struct ActivityJournal: Hashable, Sendable {
    /// 사무실 전체에 남겨 두는 기록 수
    public static let capacity = 400

    public private(set) var entries: [ActivityEntry] = []
    private var serial = 0

    public init() {}

    /// 한 사람의 기록 (오래된 것부터)
    public func entries(of agent: AgentID) -> [ActivityEntry] {
        entries.filter { $0.agent == agent }
    }

    /// 리듀서가 낸 비트로 기록을 고칩니다. `state`는 비트를 낸 뒤의 상태 (폴더를 찾는 데 씀)
    public mutating func record(_ beats: [Beat], in state: OfficeState, at now: Date) {
        for beat in beats {
            switch beat {
            case .working(let agent, let call):
                append(agent, .tool(call), state: .running, in: state, at: now)

            case .toolEnded(let agent, let call, let outcome):
                let result: ActivityEntry.State = switch outcome {
                case .success: .succeeded
                case .failure: .failed
                case .interrupted: .interrupted
                }
                if let index = openToolIndex(of: agent.id, matching: call) {
                    entries[index].state = result
                } else {
                    // 시작을 못 받은 툴 (Post가 먼저 왔거나 기록을 시작하기 전에 시작함)
                    append(agent, .tool(call), state: result, in: state, at: now)
                }

            case .permissionAsked(let agent, let call):
                if let index = openToolIndex(of: agent.id, matching: call, allowAny: call == nil) {
                    entries[index].state = .awaitingPermission
                    entries[index].since = now
                } else {
                    append(agent, .permission(call), state: .awaitingPermission, in: state, at: now)
                }

            case .permissionDenied(let agent, let call):
                if let index = entries.lastIndex(where: { $0.agent == agent.id && $0.state == .awaitingPermission })
                    ?? openToolIndex(of: agent.id, matching: call, allowAny: call == nil)
                {
                    entries[index].state = .denied
                } else {
                    append(agent, .permission(call), state: .denied, in: state, at: now)
                }

            case .delegated(let by, let member):
                // 서브가 보고할 때까지 진행 중 (위임한 사람의 줄에 경과 시간)
                append(by, .delegated(member: member.id, title: member.displayName), state: .running, in: state, at: now)

            case .reported(let member, let to):
                close(member.id)
                append(member, .reported(to: to?.id, title: to?.displayName), state: .succeeded, in: state, at: now)
                if let index = entries.lastIndex(where: {
                    if case .delegated(let id, _) = $0.kind { id == member.id } else { false }
                }) {
                    entries[index].state = .succeeded
                }

            case .promptArrived(let agent), .turnEnded(let agent, _):
                // 새 요청·응답 끝: 결과가 안 온 툴은 닫습니다 (리듀서도 이때 진행 중인 툴을 비움)
                close(agent.id)

            case .left(let agent):
                // 퇴근: 그 사람의 기록과, 그 사람에게 맡겼던 위임(보고 없이 세션이 끝남)을 모두 닫습니다
                close(agent.id, delegations: true)
                for index in entries.indices where entries[index].state.isOpen {
                    if case .delegated(let id, _) = entries[index].kind, id == agent.id { entries[index].state = .closed }
                }

            default:
                break
            }
        }
    }

    private mutating func append(_ agent: Agent, _ kind: ActivityEntry.Kind, state entryState: ActivityEntry.State, in state: OfficeState, at now: Date) {
        serial += 1
        let folder = state.teams[agent.teamID]?.folder
        entries.append(ActivityEntry(
            serial: serial, agent: agent.id, title: agent.displayName, folder: folder, kind: kind, at: now, state: entryState, since: now))
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
    }

    /// 아직 열린 그 사람의 툴 기록 (tool_use_id가 같으면 그것, 없으면 이름이 같은 가장 최근 것)
    private func openToolIndex(of agent: AgentID, matching call: ToolCall?, allowAny: Bool = false) -> Int? {
        let open = entries.indices.filter { entries[$0].agent == agent && entries[$0].state.isOpen && entries[$0].toolCall != nil }
        if let id = call?.id, let index = open.last(where: { entries[$0].toolCall?.id == id }) { return index }
        if let name = call?.name, let index = open.last(where: { entries[$0].toolCall?.name == name }) { return index }
        return allowAny ? open.last(where: { entries[$0].state == .running }) : nil
    }

    private mutating func close(_ agent: AgentID, delegations: Bool = false) {
        for index in entries.indices where entries[index].agent == agent && entries[index].state.isOpen {
            // 위임은 서브가 보고할 때 닫습니다 (백그라운드 서브는 응답이 끝난 뒤에도 일함)
            if case .delegated = entries[index].kind, !delegations { continue }
            entries[index].state = .closed
        }
    }
}

extension ActivityEntry {
    /// 툴 기록이면 그 툴
    var toolCall: ToolCall? {
        if case .tool(let call) = kind { return call }
        return nil
    }
}
