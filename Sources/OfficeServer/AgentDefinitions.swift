import Foundation
import OfficeCore

/// 직접 만든 에이전트의 정의 파일(`.claude/agents/*.md`)을 찾아 읽습니다 (설계서 §4.5).
///
/// 찾는 순서: 행 폴더의 `.claude/agents`, 그 위 폴더들의 `.claude/agents`(가까운 곳부터), 마지막으로 `~/.claude/agents`.
/// 같은 이름이 여럿이면 먼저 찾은 쪽(프로젝트 쪽)을 씁니다. 심볼릭 링크로 둔 파일도 읽습니다.
/// 폴더마다 읽은 결과를 `ttl`초 동안 기억하므로, 정의 파일을 고치면 그 뒤에 반영됩니다.
public final class AgentDefinitionDirectory: @unchecked Sendable {
    public static func defaultUserAgents(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".claude/agents")
    }

    public let home: URL
    public let userAgents: URL
    private let ttl: TimeInterval
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    /// 에이전트 폴더 경로 → (이름 → 정의)
    private var cache: [String: (definitions: [String: AgentDefinition], at: Date)] = [:]

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser, userAgents: URL? = nil, ttl: TimeInterval = 10,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.home = home.standardizedFileURL
        self.userAgents = (userAgents ?? Self.defaultUserAgents(home: home)).standardizedFileURL
        self.ttl = ttl
        self.now = now
    }

    /// 이름으로 정의를 찾습니다. `folder`는 그 서브가 일하는 행의 폴더(없으면 사용자 폴더만 봄).
    public func definition(named name: String, near folder: String?) -> AgentDefinition? {
        for directory in searchDirectories(from: folder) {
            if let found = definitions(in: directory)[name] { return found }
        }
        return nil
    }

    /// 찾을 `.claude/agents` 폴더들 (가까운 곳부터, 마지막은 사용자 폴더)
    func searchDirectories(from folder: String?) -> [URL] {
        var result: [URL] = []
        if let folder, folder.hasPrefix("/") {
            var url = URL(fileURLWithPath: folder, isDirectory: true).standardizedFileURL
            // 홈 바로 아래(.claude/agents = 사용자 폴더)나 맨 위에 닿으면 멈춥니다
            while url.path != home.path, url.path != "/" {
                result.append(url.appendingPathComponent(".claude/agents"))
                url = url.deletingLastPathComponent().standardizedFileURL
            }
        }
        result.append(userAgents)
        var seen = Set<String>()
        return result.filter { seen.insert($0.path).inserted }
    }

    func definitions(in directory: URL) -> [String: AgentDefinition] {
        lock.lock()
        defer { lock.unlock() }
        let key = directory.path
        if let cached = cache[key], now().timeIntervalSince(cached.at) < ttl { return cached.definitions }
        var definitions: [String: AgentDefinition] = [:]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.pathExtension == "md" {
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                let definition = AgentDefinition.parse(markdown: text),
                definitions[definition.name] == nil
            else { continue }
            definitions[definition.name] = definition
        }
        cache[key] = (definitions, now())
        return definitions
    }
}
