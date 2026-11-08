import Foundation

/// 설정 → 연동의 "테스트 이벤트 보내기" (M5(8)).
///
/// 설치된 훅 스크립트로 짧은 가짜 세션을 보냅니다: 출근 → 요청 → 파일 읽기 → 응답 끝 → 퇴근.
/// 스크립트 → 엔드포인트 파일 → 서버 → 사무실까지 실제 경로를 그대로 지나며, 이 세션의 알림은 띄우지 않습니다.
public enum HookTestScenario {
    /// 가짜 세션 id 앞부분. 이 세션의 알림은 걸러 냅니다.
    public static let sessionPrefix = "claude-office-test-"
    /// 사무실·드롭다운에 보일 디렉토리 이름
    public static let folder = "/Claude Office 테스트"

    public struct Step: Hashable, Sendable {
        /// 앞 단계를 보낸 뒤 기다릴 시간 (초)
        public let delay: TimeInterval
        public let event: String
        public let payload: String
    }

    public static func sessionID(at date: Date) -> String {
        "\(sessionPrefix)\(Int(date.timeIntervalSince1970))"
    }

    public static func isTestSession(_ session: String) -> Bool {
        session.hasPrefix(sessionPrefix)
    }

    public static func steps(session: String) -> [Step] {
        func payload(_ event: String, _ extra: String = "") -> String {
            #"{"session_id":"\#(session)","cwd":"\#(folder)","hook_event_name":"\#(event)"\#(extra.isEmpty ? "" : "," + extra)}"#
        }
        let read = #""tool_name":"Read","tool_use_id":"\#(session)-read","tool_input":{"file_path":"\#(folder)/README.md"}"#
        return [
            Step(delay: 0, event: "SessionStart", payload: payload("SessionStart", #""source":"startup""#)),
            Step(delay: 2.5, event: "UserPromptSubmit", payload: payload("UserPromptSubmit", #""prompt":"연결 확인""#)),
            Step(delay: 2.0, event: "PreToolUse", payload: payload("PreToolUse", read)),
            Step(delay: 2.0, event: "PostToolUse", payload: payload("PostToolUse", read + #","tool_response":{}"#)),
            Step(delay: 1.5, event: "Stop", payload: payload("Stop")),
            Step(delay: 3.0, event: "SessionEnd", payload: payload("SessionEnd", #""reason":"other""#)),
        ]
    }

    /// 시나리오 전체 길이 (초)
    public static var duration: TimeInterval {
        steps(session: "x").reduce(0) { $0 + $1.delay }
    }

    /// 테스트 세션의 알림은 띄우지 않습니다 (지우기는 그대로 둠)
    public static func withoutTestNotices(_ actions: [NoticeAction]) -> [NoticeAction] {
        actions.filter {
            if case .post(let notice) = $0 { return !isTestSession(notice.session.raw) }
            return true
        }
    }
}
