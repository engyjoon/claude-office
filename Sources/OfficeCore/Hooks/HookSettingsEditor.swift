import Foundation

/// `claude --version` 출력에서 읽은 버전
public struct ClaudeVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// "2.1.318 (Claude Code)" 같은 문자열에서 첫 번째 x.y.z를 찾습니다.
    public init?(parsing text: String) {
        guard let match = text.firstMatch(of: /(\d+)\.(\d+)\.(\d+)/),
            let major = Int(match.1), let minor = Int(match.2), let patch = Int(match.3)
        else { return nil }
        self.init(major, minor, patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: ClaudeVersion, rhs: ClaudeVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

public enum HookSettingsError: Error, Equatable, CustomStringConvertible {
    case rootIsNotObject
    case hooksIsNotObject

    public var description: String {
        switch self {
        case .rootIsNotObject: "settings.json의 최상위가 JSON 객체가 아닙니다"
        case .hooksIsNotObject: "settings.json의 \"hooks\" 항목이 JSON 객체가 아닙니다"
        }
    }
}

/// `~/.claude/settings.json`에 Claude Office 훅을 넣고 빼는 순수 함수 모음 (설계서 §4.3).
///
/// - 우리 항목은 명령 경로에 `marker`가 들어 있는지로 구분합니다.
/// - 다른 훅과 키 순서는 그대로 둡니다.
/// - 여러 번 설치해도 결과가 같습니다.
public enum HookSettingsEditor {
    public static let defaultMarker = "claude-office.sh"

    public static let baseEvents = [
        "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "Notification", "Stop", "SubagentStop", "PreCompact",
    ]
    public static let extendedEvents = [
        "SubagentStart", "PermissionRequest", "PermissionDenied", "PostToolUseFailure", "StopFailure",
    ]
    /// 확장 이벤트를 실행 파일의 훅 스키마에서 확인한 버전
    public static let extendedMinimumVersion = ClaudeVersion(2, 1, 318)
    static let toolEvents: Set<String> = ["PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest", "PermissionDenied"]

    /// 지원하지 않는 이벤트 이름이 설정 검증 오류를 낼 수 있으므로, 확인된 버전 이상에서만 확장 이벤트를 넣습니다.
    public static func recommendedEvents(for version: ClaudeVersion?) -> [String] {
        guard let version, version >= extendedMinimumVersion else { return baseEvents }
        return baseEvents + extendedEvents
    }

    public static func install(
        into settings: JSONValue, command: String, events: [String], marker: String = defaultMarker
    ) throws -> JSONValue {
        var (root, hooks) = try split(settings)
        hooks = removingOurs(from: hooks, marker: marker).hooks
        for event in events {
            var groups = hooks[event]?.arrayValue ?? []
            var handler = JSONObject()
            handler["type"] = "command"
            handler["command"] = .string(command)
            var group = JSONObject()
            if toolEvents.contains(event) { group["matcher"] = "*" }
            group["hooks"] = .array([.object(handler)])
            groups.append(.object(group))
            hooks[event] = .array(groups)
        }
        root["hooks"] = .object(hooks)
        return .object(root)
    }

    public static func uninstall(from settings: JSONValue, marker: String = defaultMarker) throws -> (settings: JSONValue, removed: Int) {
        var (root, hooks) = try split(settings)
        let result = removingOurs(from: hooks, marker: marker)
        hooks = result.hooks
        root["hooks"] = hooks.isEmpty ? nil : .object(hooks)
        return (.object(root), result.removed)
    }

    public static func installedEvents(in settings: JSONValue, marker: String = defaultMarker) -> [String] {
        guard let hooks = settings["hooks"]?.objectValue else { return [] }
        return hooks.entries.compactMap { entry in
            (entry.value.arrayValue ?? []).contains { isOurs($0, marker: marker) } ? entry.key : nil
        }
    }

    // MARK: -

    private static func split(_ settings: JSONValue) throws -> (JSONObject, JSONObject) {
        guard let root = settings.objectValue else { throw HookSettingsError.rootIsNotObject }
        switch root["hooks"] {
        case .none, .some(.null): return (root, JSONObject())
        case .some(.object(let hooks)): return (root, hooks)
        default: throw HookSettingsError.hooksIsNotObject
        }
    }

    private static func isOurs(_ group: JSONValue, marker: String) -> Bool {
        (group["hooks"]?.arrayValue ?? []).contains { $0["command"]?.stringValue?.contains(marker) == true }
    }

    private static func removingOurs(from hooks: JSONObject, marker: String) -> (hooks: JSONObject, removed: Int) {
        var result = hooks
        var removed = 0
        for entry in hooks.entries {
            guard let groups = entry.value.arrayValue else { continue }
            let kept = groups.filter { !isOurs($0, marker: marker) }
            removed += groups.count - kept.count
            if kept.count != groups.count {
                result[entry.key] = kept.isEmpty ? nil : .array(kept)
            }
        }
        return (result, removed)
    }
}
