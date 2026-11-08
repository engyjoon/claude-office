import Foundation
import OfficeCore

/// Claude 데스크톱 앱이 세션마다 남기는 정보 파일 하나 (설계서 §4.4).
///
/// `~/Library/Application Support/Claude/claude-code-sessions/<계정>/<조직>/<local_id>.json`
/// 공개 API가 아니므로 필요한 필드만 관대하게 읽고, 형식이 바뀌어 읽지 못하면 nil입니다 (그러면 폴더 규칙으로 대체).
public struct DesktopSessionRecord: Hashable, Sendable {
    /// 데스크톱 세션 id (`local_…`)
    public var localID: String
    /// Claude Code CLI 세션 id = 훅의 `session_id`
    public var cliSessionID: String?
    public var cwd: String?
    public var originCwd: String?
    /// 이 세션을 띄운 데스크톱 세션 (`spawnedFrom.sessionId`). 사용자가 직접 연 메인 세션은 nil.
    public var parentLocalID: String?
    public var title: String?

    public init(localID: String, cliSessionID: String?, cwd: String?, originCwd: String?, parentLocalID: String?, title: String?) {
        self.localID = localID
        self.cliSessionID = cliSessionID
        self.cwd = cwd
        self.originCwd = originCwd
        self.parentLocalID = parentLocalID
        self.title = title
    }

    public static func parse(_ data: Data, localID: String) -> DesktopSessionRecord? {
        guard let json = try? JSONValue.parse(data), case .object = json else { return nil }
        func text(_ value: JSONValue?) -> String? {
            guard let string = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty else { return nil }
            return string
        }
        let parent = text(json["spawnedFrom"]?["sessionId"]).flatMap { HookRequestPolicy.isHostSessionID($0) ? $0 : nil }
        return DesktopSessionRecord(
            localID: localID,
            cliSessionID: text(json["cliSessionId"]),
            cwd: text(json["cwd"]),
            originCwd: text(json["originCwd"]),
            parentLocalID: parent,
            title: text(json["title"])
        )
    }

    /// 방을 정할 때 쓰는 폴더 (워크트리 세션은 originCwd가 원래 폴더일 수 있어 먼저 봅니다)
    var folder: String? { originCwd ?? cwd }
}

/// 데스크톱 앱 세션 정보 파일을 찾아 읽고, 훅 이벤트에 붙일 방 힌트(`SessionHint`)를 만듭니다.
///
/// 훅 서버의 전달 큐(백그라운드)에서 부르므로 내부 캐시는 잠금으로 보호합니다.
/// 파일은 훅마다 다시 읽지 않고 `ttl` 동안 캐시합니다 (제목은 바뀔 수 있어 주기적으로 새로 읽습니다).
public final class DesktopSessionDirectory: @unchecked Sendable {
    /// `~/Library/Application Support/Claude/claude-code-sessions`
    public static func defaultRoot(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
    }

    /// 부모를 따라 올라가는 최대 깊이 (순환 방지)
    static let maxDepth = 8

    public let root: URL
    private let ttl: TimeInterval
    private let missTTL: TimeInterval
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var cache: [String: (record: DesktopSessionRecord?, at: Date)] = [:]
    private var folders: (urls: [URL], at: Date)?

    public init(
        root: URL = DesktopSessionDirectory.defaultRoot(), ttl: TimeInterval = 10, missTTL: TimeInterval = 2,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.root = root
        self.ttl = ttl
        self.missTTL = missTTL
        self.now = now
    }

    /// 데스크톱 세션 id로 방 힌트를 만듭니다. 정보 파일이 없거나 읽지 못하면 nil.
    public func hint(forHostSession localID: String) -> SessionHint? {
        guard let record = record(localID) else { return nil }
        var ancestors: [SessionID] = []
        var rootRecord = record
        var visited: Set<String> = [record.localID]
        var parentID = record.parentLocalID
        while let id = parentID, visited.count <= Self.maxDepth, visited.insert(id).inserted {
            guard let parent = self.record(id) else { break }
            if let cli = parent.cliSessionID { ancestors.append(SessionID(cli)) }
            rootRecord = parent
            parentID = parent.parentLocalID
        }
        return SessionHint(hostSession: record.localID, ancestors: ancestors, rootCwd: rootRecord.folder, title: record.title)
    }

    /// 캐시된 정보 파일 (없으면 찾아서 읽습니다)
    public func record(_ localID: String) -> DesktopSessionRecord? {
        guard HookRequestPolicy.isHostSessionID(localID) else { return nil }
        let current = now()
        lock.lock()
        if let cached = cache[localID] {
            let age = current.timeIntervalSince(cached.at)
            if age < (cached.record == nil ? missTTL : ttl) {
                lock.unlock()
                return cached.record
            }
        }
        lock.unlock()

        let record = load(localID, at: current)
        lock.lock()
        cache[localID] = (record, current)
        lock.unlock()
        return record
    }

    private func load(_ localID: String, at current: Date) -> DesktopSessionRecord? {
        let name = "\(localID).json"
        for refresh in [false, true] {
            for folder in accountFolders(refresh: refresh, at: current) {
                let url = folder.appendingPathComponent(name)
                if let data = try? Data(contentsOf: url) {
                    return DesktopSessionRecord.parse(data, localID: localID)
                }
            }
        }
        return nil
    }

    /// `<계정>/<조직>` 폴더 목록 (30초 캐시, 못 찾으면 한 번 새로 고침)
    private func accountFolders(refresh: Bool, at current: Date) -> [URL] {
        lock.lock()
        if !refresh, let folders, current.timeIntervalSince(folders.at) < 30 {
            lock.unlock()
            return folders.urls
        }
        lock.unlock()
        let fileManager = FileManager.default
        var urls: [URL] = []
        let accounts = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        for account in accounts.sorted() where !account.hasPrefix(".") {
            let accountURL = root.appendingPathComponent(account)
            let orgs = (try? fileManager.contentsOfDirectory(atPath: accountURL.path)) ?? []
            for org in orgs.sorted() where !org.hasPrefix(".") {
                var isDirectory: ObjCBool = false
                let url = accountURL.appendingPathComponent(org)
                if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    urls.append(url)
                }
            }
        }
        lock.lock()
        folders = (urls, current)
        lock.unlock()
        return urls
    }
}
