import Foundation
import OfficeCore

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// 앱이 훅 스크립트 위치(포트와 토큰)를 알려주는 파일 (설계서 §4.2)
public enum EndpointFile {
    /// 엔드포인트 파일이 이 서버(포트·토큰)의 것인지
    public enum State: Hashable, Sendable {
        /// 이 서버의 포트와 토큰이 적혀 있음
        case ours
        /// 파일이 없음 (다른 프로세스가 끝나며 지웠거나 누가 지움)
        case missing
        /// 다른 포트나 토큰이 적혀 있음 (다른 프로세스가 가로챔, 예: 설치된 앱이 켜진 채 `make serve`)
        case other(port: UInt16)
        /// 읽을 수 없거나 형식이 다름
        case unreadable
    }

    /// `~/Library/Application Support/ClaudeOffice/endpoint`
    public static func defaultURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/ClaudeOffice/endpoint")
    }

    /// 폴더는 700, 파일은 600 권한으로 씁니다. 같은 폴더의 임시 파일을 `rename(2)`로 옮겨, 훅 스크립트는
    /// 언제 읽어도 옛 내용이나 새 내용 중 하나를 온전히 봅니다(지운 뒤 옮기면 그 사이에 파일이 없음).
    public static func write(port: UInt16, token: String, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".endpoint.\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: Data("\(port) \(token)\n".utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(temporary.path, url.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: temporary)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    public static func read(from url: URL) throws -> (port: UInt16, token: String) {
        let text = try String(contentsOf: url, encoding: .utf8)
        let parts = text.split(whereSeparator: \.isWhitespace)
        guard parts.count >= 2, let port = UInt16(parts[0]) else { throw CocoaError(.fileReadCorruptFile) }
        return (port, String(parts[1]))
    }

    /// 파일에 이 서버의 포트·토큰이 적혀 있는지
    public static func state(at url: URL, port: UInt16, token: String) -> State {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let found = try? read(from: url) else { return .unreadable }
        return found.port == port && found.token == token ? .ours : .other(port: found.port)
    }

    /// 파일에 이 서버의 포트·토큰이 적혀 있을 때만 지웁니다. 다른 프로세스가 덮어쓴 파일은 그 프로세스의 것이라 두고,
    /// 다른 프로세스가 끝나며 우리 파일을 지우는 일도 없습니다. 지웠으면 true.
    @discardableResult
    public static func removeIfOwned(at url: URL, port: UInt16, token: String) -> Bool {
        guard state(at: url, port: port, token: token) == .ours else { return false }
        return (try? FileManager.default.removeItem(at: url)) != nil
    }
}

/// `~/.claude/hooks/claude-office.sh`와 `~/.claude/settings.json`을 다루는 설치기.
/// JSON을 고치는 규칙은 `HookSettingsEditor`(OfficeCore)에 있고, 여기서는 파일 입출력만 합니다.
public struct HookInstaller: Sendable {
    public enum Status: Hashable, Sendable {
        case notInstalled
        case installed(events: [String])
        /// settings.json에는 있지만 스크립트가 없거나 앱에 들어 있는 것과 다름
        case scriptMissingOrOutdated(events: [String])
        case settingsUnreadable(String)
    }

    public struct Report: Hashable, Sendable {
        public var events: [String]
        public var backup: URL?
        public var version: ClaudeVersion?
    }

    public var home: URL
    /// 관리 설정(조직 정책) 폴더. macOS에서 Claude Code는 여기의 `managed-settings.json`과
    /// `managed-settings.d/*.json`을 읽습니다. 읽을 수 없으면 확인하지 않습니다.
    public var managedDirectory: URL

    public static let defaultManagedDirectory = URL(fileURLWithPath: "/Library/Application Support/ClaudeCode")

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, managedDirectory: URL = defaultManagedDirectory) {
        self.home = home
        self.managedDirectory = managedDirectory
    }

    public var scriptURL: URL { home.appendingPathComponent(".claude/hooks/claude-office.sh") }
    public var settingsURL: URL { home.appendingPathComponent(".claude/settings.json") }

    public enum InstallError: Error, Equatable, CustomStringConvertible {
        case scriptResourceMissing

        public var description: String {
            switch self {
            case .scriptResourceMissing: "앱에 훅 스크립트(claude-office.sh)가 들어 있지 않습니다. 앱을 다시 설치해 주세요."
            }
        }
    }

    /// 패키지에 들어 있는 훅 스크립트. 처음 쓸 때 한 번만 읽습니다(상태를 새로 읽을 때마다 읽으면, `make install`이
    /// 번들을 바꾸는 사이에 리소스가 잠깐 없을 수 있음). 읽지 못하면 nil이고 앱은 죽지 않습니다.
    public static let bundledScriptText: String? = {
        guard let url = Bundle.module.url(forResource: "claude-office", withExtension: "sh") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }()

    /// 패키지에 들어 있는 훅 스크립트 (읽지 못했으면 빈 문자열)
    public static var bundledScript: String { bundledScriptText ?? "" }

    /// 남겨 둘 settings.json 백업 수 (우리가 만든 `settings.json.bak-*`만 셉니다)
    public static let keptBackups = 5

    /// settings.json에 넣을 명령. 경로에 공백이 있으면 따옴표로 감쌉니다.
    public var command: String {
        scriptURL.path.contains(" ") ? "\"\(scriptURL.path)\"" : scriptURL.path
    }

    public func status() -> Status {
        let settings: JSONValue
        do {
            settings = try readSettings()
        } catch {
            return .settingsUnreadable("\(error)")
        }
        let events = HookSettingsEditor.installedEvents(in: settings)
        guard !events.isEmpty else { return .notInstalled }
        let current = try? String(contentsOf: scriptURL, encoding: .utf8)
        // 번들 스크립트를 읽지 못했으면 비교할 수 없으니, 파일이 있기만 하면 설치된 것으로 봅니다
        let upToDate = Self.bundledScriptText.map { current == $0 } ?? (current != nil)
        return upToDate ? .installed(events: events) : .scriptMissingOrOutdated(events: events)
    }

    /// 훅이 등록돼 있어도 실행되지 않게 막는 설정. 사용자 설정을 먼저, 그다음 관리 설정을 봅니다.
    /// 읽을 수 없거나 깨진 파일은 건너뜁니다(사용자 설정이 깨진 경우는 `status()`가 알립니다).
    public func blocker() -> HookBlocker? {
        if let settings = try? readSettings(), let found = HookSettingsEditor.blocker(in: settings, managed: false) {
            return found
        }
        let fileManager = FileManager.default
        var files = [managedDirectory.appendingPathComponent("managed-settings.json")]
        let dropIns = managedDirectory.appendingPathComponent("managed-settings.d")
        if let names = try? fileManager.contentsOfDirectory(atPath: dropIns.path) {
            files += names.filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.sorted().map { dropIns.appendingPathComponent($0) }
        }
        for file in files {
            guard fileManager.isReadableFile(atPath: file.path), let data = try? Data(contentsOf: file),
                let settings = try? JSONValue.parse(data),
                let found = HookSettingsEditor.blocker(in: settings, managed: true)
            else { continue }
            return found
        }
        return nil
    }

    /// 스크립트를 쓰고, settings.json을 백업한 뒤 훅을 병합합니다. 여러 번 해도 결과가 같습니다.
    /// settings.json이 바뀌지 않으면(이미 같은 훅이 있음) 쓰지도 백업하지도 않습니다(`backup == nil`).
    @discardableResult
    public func install(version: ClaudeVersion?) throws -> Report {
        guard let script = Self.bundledScriptText else { throw InstallError.scriptResourceMissing }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? String(contentsOf: scriptURL, encoding: .utf8)) != script {
            try Data(script.utf8).write(to: scriptURL, options: .atomic)
        }
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let settings = try readSettings()
        let events = HookSettingsEditor.recommendedEvents(for: version)
        let updated = try HookSettingsEditor.install(into: settings, command: command, events: events)
        let backup = updated == settings ? nil : try writeSettings(updated)
        return Report(events: events, backup: backup, version: version)
    }

    /// 우리 훅(핸들러)만 지우고 스크립트를 삭제합니다. 지운 핸들러 수를 돌려줍니다.
    @discardableResult
    public func uninstall() throws -> Int {
        let settings = try readSettings()
        let (updated, removed) = try HookSettingsEditor.uninstall(from: settings)
        if removed > 0, updated != settings { try writeSettings(updated) }
        try? FileManager.default.removeItem(at: scriptURL)
        return removed
    }

    /// settings.json이 심볼릭 링크(dotfiles 저장소 등)면 그 대상. 링크가 아니면 그대로.
    /// 원자적 쓰기는 경로의 파일을 새 파일로 바꾸므로, 링크 자체에 쓰면 링크가 일반 파일로 바뀝니다.
    public var settingsTargetURL: URL {
        var url = settingsURL
        for _ in 0..<16 {
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else { break }
            url = destination.hasPrefix("/")
                ? URL(fileURLWithPath: destination)
                : url.deletingLastPathComponent().appendingPathComponent(destination)
            url = url.standardizedFileURL
        }
        return url
    }

    /// 지금 있는 우리 백업 (`settings.json.bak-yyyyMMdd-HHmmss[-n]`), 오래된 것부터
    public func backups() -> [URL] {
        let directory = settingsURL.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.wholeMatch(of: /settings\.json\.bak-\d{8}-\d{6}(-\d+)?/) != nil }
            .sorted { lhs, rhs in Self.backupOrder(lhs) < Self.backupOrder(rhs) }
            .map { directory.appendingPathComponent($0) }
    }

    /// "settings.json.bak-20261111-120000-2" → ("20261111-120000", 2)
    private static func backupOrder(_ name: String) -> (String, Int) {
        let stamp = name.dropFirst("settings.json.bak-".count)
        let parts = stamp.split(separator: "-")
        return (parts.prefix(2).joined(separator: "-"), parts.count > 2 ? Int(parts[2]) ?? 0 : 1)
    }

    // MARK: -

    func readSettings() throws -> JSONValue {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return .object(JSONObject()) }
        let data = try Data(contentsOf: settingsURL)
        if data.allSatisfy({ [0x20, 0x09, 0x0A, 0x0D].contains($0) }) { return .object(JSONObject()) }
        return try JSONValue.parse(data)
    }

    /// 바뀐 settings.json을 씁니다. 링크면 대상에 쓰고, 원래 파일이 있으면 먼저 백업하고 백업은 최근 `keptBackups`개만 둡니다.
    @discardableResult
    private func writeSettings(_ settings: JSONValue) throws -> URL? {
        let fileManager = FileManager.default
        let target = settingsTargetURL
        var backup: URL?
        var permissions: Any?
        if fileManager.fileExists(atPath: target.path) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let stamp = formatter.string(from: Date())
            let folder = settingsURL.deletingLastPathComponent()
            var candidate = folder.appendingPathComponent("settings.json.bak-\(stamp)")
            var suffix = 1
            while fileManager.fileExists(atPath: candidate.path) {
                suffix += 1
                candidate = folder.appendingPathComponent("settings.json.bak-\(stamp)-\(suffix)")
            }
            // 링크를 복사하지 않도록 내용을 복사합니다
            let original = try Data(contentsOf: target)
            guard fileManager.createFile(atPath: candidate.path, contents: original, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            backup = candidate
            permissions = try? fileManager.attributesOfItem(atPath: target.path)[.posixPermissions]
        } else {
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try Data((settings.serialized() + "\n").utf8).write(to: target, options: .atomic)
        if let permissions { try? fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path) }
        pruneBackups()
        return backup
    }

    /// 우리 이름 꼴의 백업만, 오래된 것부터 지워 `keptBackups`개를 남깁니다
    private func pruneBackups() {
        let all = backups()
        guard all.count > Self.keptBackups else { return }
        for url in all.prefix(all.count - Self.keptBackups) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// `claude --version`을 실행해 버전을 알아냅니다.
///
/// Finder·로그인 항목으로 켠 앱은 PATH가 `/usr/bin:/bin:/usr/sbin:/sbin`뿐이고, 로그인 zsh도 `~/.zshrc`를 읽지 않아
/// `~/.local/bin/claude`를 못 찾습니다. 그래서 알려진 설치 위치와 PATH를 먼저 직접 실행하고, 그래도 없으면 로그인 셸을 씁니다.
public enum ClaudeVersionDetector {
    /// 직접 실행해 볼 위치: 기본 설치기(`~/.local/bin`), 예전 로컬 설치(`~/.claude/local`), Homebrew, npm 전역, 그다음 PATH
    public static func candidates(home: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        var paths = [
            home.appendingPathComponent(".local/bin/claude").path,
            home.appendingPathComponent(".claude/local/claude").path,
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        for directory in (environment["PATH"] ?? "").split(separator: ":") where !directory.isEmpty {
            paths.append(URL(fileURLWithPath: String(directory)).appendingPathComponent("claude").path)
        }
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    public static func detect(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        shells: [String]? = nil,
        timeout: TimeInterval = 5
    ) -> ClaudeVersion? {
        for path in candidates(home: home, environment: environment) where FileManager.default.isExecutableFile(atPath: path) {
            if let output = run(path, ["--version"], timeout: timeout), let version = ClaudeVersion(parsing: output) {
                return version
            }
        }
        let shells = shells ?? [environment["SHELL"], "/bin/zsh", "/bin/bash"].compactMap { $0 }
        for shell in shells where FileManager.default.isExecutableFile(atPath: shell) {
            if let output = run(shell, ["-lc", "claude --version"], timeout: timeout), let version = ClaudeVersion(parsing: output) {
                return version
            }
        }
        return nil
    }

    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }
}
