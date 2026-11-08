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
    /// 데스크톱 앱에서 보관(닫음)한 세션
    public var isArchived: Bool
    /// 마지막 활동 시각 (`lastActivityAt`, 밀리초)
    public var lastActivity: Date?
    /// 만든 시각 (`createdAt`, 밀리초). 같은 행의 서브를 앉히는 순서에 씀.
    public var createdAt: Date?

    public init(
        localID: String, cliSessionID: String?, cwd: String?, originCwd: String?, parentLocalID: String?, title: String?,
        isArchived: Bool = false, lastActivity: Date? = nil, createdAt: Date? = nil
    ) {
        self.createdAt = createdAt
        self.localID = localID
        self.cliSessionID = cliSessionID
        self.cwd = cwd
        self.originCwd = originCwd
        self.parentLocalID = parentLocalID
        self.title = title
        self.isArchived = isArchived
        self.lastActivity = lastActivity
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
            title: text(json["title"]),
            isArchived: json["isArchived"]?.boolValue ?? false,
            lastActivity: json["lastActivityAt"]?.doubleValue.map { Date(timeIntervalSince1970: $0 / 1000) },
            createdAt: json["createdAt"]?.doubleValue.map { Date(timeIntervalSince1970: $0 / 1000) }
        )
    }

    /// 방을 정할 때 쓰는 폴더 (워크트리 세션은 originCwd가 원래 폴더일 수 있어 먼저 봅니다)
    var folder: String? { originCwd ?? cwd }
}

/// 데스크톱 앱에 열려 있는 디렉토리 하나 (직원 현황 패널 위 디렉토리 목록, 2026-11-08)
public struct DesktopFolder: Identifiable, Hashable, Sendable {
    /// `Team.folder`와 같은 형식의 경로 (워크트리는 원래 폴더)
    public var path: String
    /// 그 폴더에서 열려 있는(보관하지 않은) 세션 수
    public var sessions: Int
    public var lastActivity: Date?

    public init(path: String, sessions: Int, lastActivity: Date? = nil) {
        self.path = path
        self.sessions = sessions
        self.lastActivity = lastActivity
    }

    public var id: String { path }
    /// 폴더 이름
    public var name: String { path.split(separator: "/").last.map(String.init) ?? path }
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
    /// `allRecords`가 읽은 파일 (경로 → 수정 시각·크기·읽은 기록). 바뀌지 않은 파일은 다시 파싱하지 않습니다 (M6(1)).
    private var parsedFiles: [String: (stamp: FileStamp, record: DesktopSessionRecord?)] = [:]
    /// 마지막 `allRecords`에서 실제로 파싱한 파일 수 (테스트·계측용)
    public private(set) var lastParsedCount = 0

    struct FileStamp: Equatable {
        var modified: Date
        var size: Int
    }

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
        let hasRoot = !ancestors.isEmpty && rootRecord.localID != record.localID
        return SessionHint(
            hostSession: record.localID, ancestors: ancestors, rootCwd: rootRecord.folder, title: record.title,
            rootHostSession: hasRoot ? rootRecord.localID : nil, rootTitle: hasRoot ? rootRecord.title : nil,
            rootIsOpen: hasRoot && !rootRecord.isArchived && rootRecord.cliSessionID == ancestors.last?.raw,
            hostCliSession: record.cliSessionID.map(SessionID.init))
    }

    /// 세션 정보 파일을 모두 다시 읽습니다 (보관한 세션 포함). 메인 스레드가 아닌 곳에서 가끔(몇 초마다) 부르세요.
    ///
    /// 수정 시각과 크기가 지난번과 같은 파일은 다시 파싱하지 않습니다 (M6(1): 파일 30개·1MB를 5초마다 다시 파싱하던 것이
    /// 대기 중 CPU의 큰 몫이었음). 데스크톱 앱은 파일을 통째로 다시 쓰므로 수정 시각이 바뀝니다.
    public func allRecords() -> [DesktopSessionRecord] {
        let fileManager = FileManager.default
        var records: [DesktopSessionRecord] = []
        var seen: Set<String> = []
        var parsed = 0
        for folder in accountFolders(refresh: true, at: now()) {
            let names = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
            for name in names where name.hasSuffix(".json") {
                let localID = String(name.dropLast(5))
                guard HookRequestPolicy.isHostSessionID(localID) else { continue }
                let path = folder.appendingPathComponent(name).path
                guard let attributes = try? fileManager.attributesOfItem(atPath: path),
                      let modified = attributes[.modificationDate] as? Date,
                      let size = (attributes[.size] as? NSNumber)?.intValue else { continue }
                seen.insert(path)
                let stamp = FileStamp(modified: modified, size: size)
                let cached = lock.withLock { parsedFiles[path] }
                let record: DesktopSessionRecord?
                if let cached, cached.stamp == stamp {
                    record = cached.record
                } else {
                    record = (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap { DesktopSessionRecord.parse($0, localID: localID) }
                    parsed += 1
                    lock.withLock { parsedFiles[path] = (stamp, record) }
                }
                if let record { records.append(record) }
            }
        }
        lock.withLock {
            parsedFiles = parsedFiles.filter { seen.contains($0.key) }
            lastParsedCount = parsed
        }
        return records
    }

    /// 데스크톱 앱에 열려 있는(보관하지 않은) 세션들의 디렉토리 목록. 폴더 이름순.
    public func openFolders() -> [DesktopFolder] {
        Self.openFolders(in: allRecords())
    }

    /// 열려 있는 세션들의 디렉토리 목록 (폴더 이름순).
    /// 띄운 세션은 사무실에서 띄운 쪽 행에 앉으므로 최상위 세션의 폴더로 셉니다.
    public static func openFolders(in list: [DesktopSessionRecord]) -> [DesktopFolder] {
        var records: [String: DesktopSessionRecord] = [:]
        for record in list { records[record.localID] = record }
        var folders: [String: DesktopFolder] = [:]
        for record in records.values where !record.isArchived {
            var root = record
            var visited: Set<String> = [record.localID]
            while let parentID = root.parentLocalID, visited.count <= Self.maxDepth, visited.insert(parentID).inserted,
                  let parent = records[parentID] {
                root = parent
            }
            guard let raw = root.folder ?? record.folder else { continue }
            let path = Team.folder(for: raw)
            var entry = folders[path] ?? DesktopFolder(path: path, sessions: 0)
            entry.sessions += 1
            if let activity = record.lastActivity, entry.lastActivity.map({ $0 < activity }) ?? true { entry.lastActivity = activity }
            folders[path] = entry
        }
        return folders.values.sorted { a, b in
            let order = a.name.localizedStandardCompare(b.name)
            return order == .orderedSame ? a.path < b.path : order == .orderedAscending
        }
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

/// 데스크톱 앱에 열려 있는 세션 중 사무실에 미리 "쉬는 중"으로 앉힐 사람을 고릅니다 (설계서 §5.2, M5(5)). 순수 계산.
///
/// - 대상: 보관하지 않았고(`!isArchived`) 훅과 이어 줄 CLI 세션 id(`cliSessionId`)가 있는 세션. 활동 기간은 따지지 않습니다:
///   데스크톱 앱 사이드바와 디렉토리 드롭다운이 보여 주는 세션과 같게 (2026-11-08 실제 목록: 열린 디렉토리 4개 중 3개가 3~11일 전 활동).
/// - 관계: 부모(`spawnedFrom`)를 따라 올라가며 조상의 CLI 세션 id를 모읍니다 (보관한 부모 포함, 사무실에 없는 부모는 리듀서가 건너뜀).
/// - 순서: 최근에 활동한 행이 먼저(위 행, 작은 메인 번호), 행 안에서는 부모가 먼저, 그다음 만든 순서.
/// - 서브에이전트는 훅으로만 알 수 있어 앉히지 않습니다.
public enum DesktopResidents {
    public static func roll(from list: [DesktopSessionRecord], readAt: Date) -> ResidentRoll {
        var records: [String: DesktopSessionRecord] = [:]
        for record in list { records[record.localID] = record }
        let open = records.values.filter { !$0.isArchived }

        struct Entry {
            var record: DesktopSessionRecord
            var resident: ResidentSession
            /// 열려 있는 가장 위 조상 (같은 행이 될 묶음)
            var group: String
            var depth: Int
        }
        var entries: [Entry] = []
        for record in open {
            guard let cli = record.cliSessionID else { continue }
            var ancestors: [SessionID] = []
            var root = record
            var group = record.localID
            var visited: Set<String> = [record.localID]
            var parentID = record.parentLocalID
            while let id = parentID, visited.count <= DesktopSessionDirectory.maxDepth, visited.insert(id).inserted,
                  let parent = records[id] {
                if let parentCli = parent.cliSessionID { ancestors.append(SessionID(parentCli)) }
                if !parent.isArchived, parent.cliSessionID != nil { group = parent.localID }
                root = parent
                parentID = parent.parentLocalID
            }
            let resident = ResidentSession(
                session: SessionID(cli), hostSession: record.localID, ancestors: ancestors, rootCwd: root.folder ?? record.folder,
                title: record.title, lastActivity: record.lastActivity)
            entries.append(Entry(record: record, resident: resident, group: group, depth: ancestors.count))
        }

        // 행(묶음)의 최근 활동 = 묶음 안에서 가장 최근
        var groupActivity: [String: Date] = [:]
        for entry in entries {
            let activity = entry.record.lastActivity ?? .distantPast
            groupActivity[entry.group] = max(groupActivity[entry.group] ?? .distantPast, activity)
        }
        entries.sort { a, b in
            if a.group != b.group {
                let (x, y) = (groupActivity[a.group]!, groupActivity[b.group]!)
                return x != y ? x > y : a.group < b.group
            }
            if a.depth != b.depth { return a.depth < b.depth }
            let (x, y) = (a.record.createdAt ?? .distantPast, b.record.createdAt ?? .distantPast)
            return x != y ? x < y : a.record.localID < b.record.localID
        }
        return ResidentRoll(
            residents: entries.map(\.resident), openHostSessions: Set(open.map(\.localID)), isReliable: !records.isEmpty,
            readAt: readAt)
    }
}
