import Foundation
import OfficeCore

/// 훅 스크립트 파일 상태
public enum HookScriptState: Hashable, Sendable {
    /// 앱에 들어 있는 것과 같고 실행할 수 있음
    case current
    case missing
    /// 내용은 같지만 실행 권한이 없음
    case notExecutable
    /// 앱에 들어 있는 것과 내용이 다름 (옛 버전이거나 고친 파일)
    case outdated
}

extension HookInstaller {
    public func scriptState() -> HookScriptState {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: scriptURL.path) else { return .missing }
        guard (try? String(contentsOf: scriptURL, encoding: .utf8)) == Self.bundledScript else { return .outdated }
        return fileManager.isExecutableFile(atPath: scriptURL.path) ? .current : .notExecutable
    }
}

/// 설정 → 연동의 훅 상태 판정 (M5(8)). 화면은 이 결과만 그립니다.
public struct HookHealth: Hashable, Sendable {
    public enum Level: Hashable, Sendable, Comparable {
        case ok, idle, warning, error
    }

    public struct Item: Hashable, Sendable, Identifiable {
        public let label: String
        public let value: String
        public let level: Level
        public var id: String { label }
    }

    /// 전체 판정: 가장 나쁜 항목을 따르되, 할 일을 한 줄로 알려 줍니다
    public let level: Level
    public let headline: String
    public let items: [Item]
    /// 다시 설치를 권할지 (스크립트가 없거나 옛 버전, 실행 권한 없음)
    public let suggestsReinstall: Bool

    public struct Input: Hashable, Sendable {
        public var status: HookInstaller.Status
        public var script: HookScriptState
        /// 실행 중이면 포트, 멈췄으면 nil
        public var port: UInt16?
        /// 서버를 시작하지 못한 까닭
        public var serverError: String?
        public var lastEventAt: Date?
        public var eventCount: Int

        public init(status: HookInstaller.Status, script: HookScriptState, port: UInt16?, serverError: String? = nil,
                    lastEventAt: Date?, eventCount: Int) {
            self.status = status
            self.script = script
            self.port = port
            self.serverError = serverError
            self.lastEventAt = lastEventAt
            self.eventCount = eventCount
        }
    }

    public static func evaluate(_ input: Input, now: Date) -> HookHealth {
        var items: [Item] = []

        // settings.json 등록
        let registered: Bool
        switch input.status {
        case .notInstalled:
            registered = false
            items.append(Item(label: "settings.json 등록", value: "안 됨", level: .idle))
        case .installed(let events), .scriptMissingOrOutdated(let events):
            registered = true
            items.append(Item(label: "settings.json 등록", value: "됨 · 이벤트 \(events.count)개", level: .ok))
        case .settingsUnreadable(let reason):
            registered = false
            items.append(Item(label: "settings.json 등록", value: "읽을 수 없음 · \(reason)", level: .error))
        }

        // 스크립트 파일
        let scriptItem: Item
        switch input.script {
        case .current: scriptItem = Item(label: "훅 스크립트", value: "있음 · 실행 가능", level: .ok)
        case .missing: scriptItem = Item(label: "훅 스크립트", value: "없음", level: registered ? .warning : .idle)
        case .notExecutable: scriptItem = Item(label: "훅 스크립트", value: "실행 권한 없음", level: .warning)
        case .outdated: scriptItem = Item(label: "훅 스크립트", value: "앱과 다른 버전", level: .warning)
        }
        items.append(scriptItem)

        // 서버
        if let port = input.port {
            items.append(Item(label: "서버", value: "실행 중 · 127.0.0.1:\(port)", level: .ok))
        } else if let error = input.serverError {
            items.append(Item(label: "서버", value: "시작하지 못함 · \(error)", level: .error))
        } else {
            items.append(Item(label: "서버", value: "멈춤", level: .error))
        }

        // 받은 이벤트
        let last = input.lastEventAt.map { AgentTimeline.ago(now.timeIntervalSince($0)) } ?? "아직 없음"
        items.append(Item(label: "마지막 이벤트", value: last, level: input.lastEventAt == nil ? .idle : .ok))
        items.append(Item(label: "받은 이벤트", value: "\(input.eventCount)개 (앱을 켠 뒤)", level: input.eventCount > 0 ? .ok : .idle))

        let suggestsReinstall = registered && input.script != .current
        let level: Level
        let headline: String
        if case .settingsUnreadable = input.status {
            level = .error
            headline = "~/.claude/settings.json을 읽을 수 없어요. 파일을 고친 뒤 다시 확인해 주세요."
        } else if input.port == nil {
            level = .error
            headline = "서버가 멈춰 있어요. \"서버 다시 시작\"을 눌러 주세요."
        } else if !registered {
            level = .idle
            headline = input.script == .missing
                ? "훅이 설치되지 않았어요. \"훅 설치\"를 누르면 Claude Code 세션이 사무실에 나타나요."
                : "settings.json에 훅이 없어요. \"훅 설치\"로 다시 등록해 주세요."
        } else if suggestsReinstall {
            level = .warning
            headline = "훅 스크립트를 고쳐야 해요. \"다시 설치\"를 눌러 주세요."
        } else if input.lastEventAt == nil {
            level = .ok
            headline = "설치됨 · 아직 받은 이벤트가 없어요. 이미 실행 중인 Claude Code 세션은 다시 시작해야 이벤트가 와요."
        } else {
            level = .ok
            headline = "정상 작동 중 · 마지막 이벤트 \(last)"
        }
        return HookHealth(level: level, headline: headline, items: items, suggestsReinstall: suggestsReinstall)
    }
}
