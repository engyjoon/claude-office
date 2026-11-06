import Foundation
import OfficeCore

/// 앱이 훅 스크립트 위치(포트와 토큰)를 알려주는 파일 (설계서 §4.2)
public enum EndpointFile {
    /// `~/Library/Application Support/ClaudeOffice/endpoint`
    public static func defaultURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/ClaudeOffice/endpoint")
    }

    /// 폴더는 700, 파일은 600 권한으로 원자적으로 씁니다.
    public static func write(port: UInt16, token: String, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".endpoint.\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: Data("\(port) \(token)\n".utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        _ = try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: temporary, to: url)
    }

    public static func read(from url: URL) throws -> (port: UInt16, token: String) {
        let text = try String(contentsOf: url, encoding: .utf8)
        let parts = text.split(whereSeparator: \.isWhitespace)
        guard parts.count >= 2, let port = UInt16(parts[0]) else { throw CocoaError(.fileReadCorruptFile) }
        return (port, String(parts[1]))
    }

    public static func remove(at url: URL) {
        try? FileManager.default.removeItem(at: url)
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

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    public var scriptURL: URL { home.appendingPathComponent(".claude/hooks/claude-office.sh") }
    public var settingsURL: URL { home.appendingPathComponent(".claude/settings.json") }

    /// 패키지에 들어 있는 훅 스크립트
    public static var bundledScript: String {
        guard let url = Bundle.module.url(forResource: "claude-office", withExtension: "sh"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { preconditionFailure("claude-office.sh 리소스가 없습니다") }
        return text
    }

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
        return current == Self.bundledScript ? .installed(events: events) : .scriptMissingOrOutdated(events: events)
    }

    /// 스크립트를 쓰고, settings.json을 백업한 뒤 훅을 병합합니다. 여러 번 해도 결과가 같습니다.
    @discardableResult
    public func install(version: ClaudeVersion?) throws -> Report {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(Self.bundledScript.utf8).write(to: scriptURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let settings = try readSettings()
        let events = HookSettingsEditor.recommendedEvents(for: version)
        let updated = try HookSettingsEditor.install(into: settings, command: command, events: events)
        let backup = try writeSettings(updated)
        return Report(events: events, backup: backup, version: version)
    }

    /// 우리 훅만 지우고 스크립트를 삭제합니다. 지운 항목 수를 돌려줍니다.
    @discardableResult
    public func uninstall() throws -> Int {
        let settings = try readSettings()
        let (updated, removed) = try HookSettingsEditor.uninstall(from: settings)
        if removed > 0 { try writeSettings(updated) }
        try? FileManager.default.removeItem(at: scriptURL)
        return removed
    }

    // MARK: -

    private func readSettings() throws -> JSONValue {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return .object(JSONObject()) }
        let data = try Data(contentsOf: settingsURL)
        if data.allSatisfy({ [0x20, 0x09, 0x0A, 0x0D].contains($0) }) { return .object(JSONObject()) }
        return try JSONValue.parse(data)
    }

    @discardableResult
    private func writeSettings(_ settings: JSONValue) throws -> URL? {
        let fileManager = FileManager.default
        var backup: URL?
        if fileManager.fileExists(atPath: settingsURL.path) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            var candidate = settingsURL.deletingLastPathComponent()
                .appendingPathComponent("settings.json.bak-\(formatter.string(from: Date()))")
            var suffix = 1
            while fileManager.fileExists(atPath: candidate.path) {
                suffix += 1
                candidate = settingsURL.deletingLastPathComponent()
                    .appendingPathComponent("settings.json.bak-\(formatter.string(from: Date()))-\(suffix)")
            }
            try fileManager.copyItem(at: settingsURL, to: candidate)
            backup = candidate
        } else {
            try fileManager.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try Data((settings.serialized() + "\n").utf8).write(to: settingsURL, options: .atomic)
        return backup
    }
}

/// `claude --version`을 로그인 셸로 실행해 버전을 알아냅니다.
/// macOS 앱은 터미널과 PATH가 달라서 셸을 거쳐야 `~/.local/bin/claude` 같은 위치를 찾습니다.
public enum ClaudeVersionDetector {
    public static func detect(timeout: TimeInterval = 5) -> ClaudeVersion? {
        let shells = [ProcessInfo.processInfo.environment["SHELL"], "/bin/zsh", "/bin/bash"].compactMap { $0 }
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
