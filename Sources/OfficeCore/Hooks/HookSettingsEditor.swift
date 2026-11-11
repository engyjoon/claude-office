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

    /// `claude --version` 출력("2.1.318 (Claude Code)")에서 버전을 읽습니다.
    ///
    /// 로그인 셸을 거치면 앞에 셸 설정이 찍은 배너(예: "nvm 0.39.7", "Welcome to zsh 5.9")가 섞일 수 있어서
    /// 아무 x.y.z나 집지 않습니다: "Claude Code"가 든 줄을 먼저 보고, 없으면 버전으로 시작하는 마지막 줄만 받습니다.
    public init?(parsing text: String) {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.split(whereSeparator: \.isWhitespace) }
        let found: (Int, Int, Int)?
        if let claudeLine = lines.last(where: { $0.joined(separator: " ").localizedCaseInsensitiveContains("Claude Code") }) {
            found = claudeLine.lazy.compactMap(Self.version(token:)).first
        } else {
            found = lines.reversed().lazy.compactMap { $0.first.flatMap(Self.version(token:)) }.first
        }
        guard let found else { return nil }
        self.init(found.0, found.1, found.2)
    }

    /// 낱말 하나가 통째로 x.y.z(앞에 v 허용)일 때만 버전으로 봅니다. "1.2.3.4"나 "5.9-dev"는 아닙니다.
    private static func version(token: Substring) -> (Int, Int, Int)? {
        let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: "(),;:"))
        guard let match = trimmed.wholeMatch(of: /v?(\d+)\.(\d+)\.(\d+)/),
            let major = Int(match.1), let minor = Int(match.2), let patch = Int(match.3)
        else { return nil }
        return (major, minor, patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: ClaudeVersion, rhs: ClaudeVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

/// 훅이 등록돼 있어도 Claude Code가 실행하지 않게 만드는 설정
public enum HookBlocker: Hashable, Sendable {
    /// `disableAllHooks: true`. `managed`면 관리 설정(조직 정책)에 있음
    case disableAllHooks(managed: Bool)
    /// 관리 설정의 `allowManagedHooksOnly: true`
    case managedHooksOnly

    /// 연동 화면과 메뉴 배너에 보여 줄 문구
    public var message: String {
        switch self {
        case .disableAllHooks(managed: false):
            "~/.claude/settings.json에 \"disableAllHooks\": true가 있어 모든 훅이 꺼져 있어요. 이 줄을 지우거나 false로 바꾼 뒤 Claude Code 세션을 다시 시작해 주세요."
        case .disableAllHooks(managed: true):
            "조직의 관리 설정(managed-settings.json)에 \"disableAllHooks\": true가 있어 모든 훅이 꺼져 있어요. 관리자에게 문의해 주세요."
        case .managedHooksOnly:
            "조직의 관리 설정(managed-settings.json)에 \"allowManagedHooksOnly\": true가 있어 관리 설정의 훅만 실행돼요. Claude Office 훅은 실행되지 않으니 관리자에게 문의해 주세요."
        }
    }

    /// 항목 표에 쓰는 짧은 값
    public var shortValue: String {
        switch self {
        case .disableAllHooks(managed: false): "꺼짐 · settings.json의 disableAllHooks"
        case .disableAllHooks(managed: true): "꺼짐 · 관리 설정의 disableAllHooks"
        case .managedHooksOnly: "막힘 · 관리 설정의 allowManagedHooksOnly"
        }
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

    /// 버전으로 권하는 이벤트 중 등록되지 않은 것. 버전을 모르면 비교하지 않습니다(빈 배열).
    public static func missingEvents(installed: [String], version: ClaudeVersion?) -> [String] {
        guard version != nil else { return [] }
        let have = Set(installed)
        return recommendedEvents(for: version).filter { !have.contains($0) }
    }

    /// 설정 파일이 우리 훅을 막는 까닭. `managed`는 관리 설정(조직 정책) 파일인지입니다.
    /// - `disableAllHooks: true`: 모든 훅이 꺼집니다(사용자·관리 설정 모두).
    /// - `allowManagedHooksOnly: true`: 관리 설정에서만 의미가 있고, 사용자 설정의 훅(우리 훅)은 실행되지 않습니다.
    public static func blocker(in settings: JSONValue, managed: Bool) -> HookBlocker? {
        if settings["disableAllHooks"]?.boolValue == true { return .disableAllHooks(managed: managed) }
        if managed, settings["allowManagedHooksOnly"]?.boolValue == true { return .managedHooksOnly }
        return nil
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
        (group["hooks"]?.arrayValue ?? []).contains { isOurHandler($0, marker: marker) }
    }

    private static func isOurHandler(_ handler: JSONValue, marker: String) -> Bool {
        handler["command"]?.stringValue?.contains(marker) == true
    }

    /// 우리 핸들러만 지웁니다. 사용자가 같은 그룹에 넣어 둔 다른 핸들러와 그 그룹의 matcher 등은 그대로 두고,
    /// 핸들러가 모두 빠진 그룹과 그룹이 모두 빠진 이벤트만 지웁니다. `removed`는 지운 핸들러 수입니다.
    private static func removingOurs(from hooks: JSONObject, marker: String) -> (hooks: JSONObject, removed: Int) {
        var result = hooks
        var removed = 0
        for entry in hooks.entries {
            guard let groups = entry.value.arrayValue, groups.contains(where: { isOurs($0, marker: marker) }) else { continue }
            var kept: [JSONValue] = []
            for group in groups {
                guard isOurs(group, marker: marker), case .object(var object) = group,
                    let handlers = group["hooks"]?.arrayValue
                else {
                    kept.append(group)
                    continue
                }
                let others = handlers.filter { !isOurHandler($0, marker: marker) }
                removed += handlers.count - others.count
                if others.isEmpty { continue }
                object["hooks"] = .array(others)
                kept.append(.object(object))
            }
            result[entry.key] = kept.isEmpty ? nil : .array(kept)
        }
        return (result, removed)
    }
}
