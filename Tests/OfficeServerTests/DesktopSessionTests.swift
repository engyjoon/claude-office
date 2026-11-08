import Foundation
import OfficeCore
import Testing

@testable import OfficeServer

@Suite("데스크톱 앱 세션 정보 → 방 힌트")
struct DesktopSessionTests {
    /// `<root>/<계정>/<조직>/<id>.json` 형태로 정보 파일을 씁니다.
    func write(_ root: URL, account: String = "acc", org: String = "org", _ id: String, _ json: String) throws {
        let folder = root.appendingPathComponent(account).appendingPathComponent(org)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try json.write(to: folder.appendingPathComponent("\(id).json"), atomically: true, encoding: .utf8)
    }

    @Test("부모를 따라 올라가 조상 세션과 최상위 폴더, 제목을 만든다")
    func ancestry() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "local_main", #"{"sessionId":"local_main","cliSessionId":"cli-main","cwd":"/w/office","originCwd":"/w/office","title":"메인 작업"}"#)
        try write(root, "local_side", #"{"cliSessionId":"cli-side","cwd":"/w/office/.claude/worktrees/x","spawnedFrom":{"sessionId":"local_main","sideSession":true},"title":"M4.5a"}"#)
        // 다른 조직 폴더에 있는 손자 세션
        try write(root, org: "org2", "local_grand", #"{"cliSessionId":"cli-grand","cwd":"/elsewhere","spawnedFrom":{"sessionId":"local_side"}}"#)
        let directory = DesktopSessionDirectory(root: root)

        let main = try #require(directory.hint(forHostSession: "local_main"))
        #expect(main.ancestors.isEmpty)
        #expect(main.rootCwd == "/w/office")
        #expect(main.title == "메인 작업")

        let side = try #require(directory.hint(forHostSession: "local_side"))
        #expect(side.ancestors == [SessionID("cli-main")])
        #expect(side.rootCwd == "/w/office")
        #expect(side.hostSession == "local_side")

        let grand = try #require(directory.hint(forHostSession: "local_grand"))
        #expect(grand.ancestors == [SessionID("cli-side"), SessionID("cli-main")])
        #expect(grand.rootCwd == "/w/office")
        #expect(grand.title == nil)
    }

    @Test("파일이 없거나 형식이 다르거나 id가 이상하면 힌트가 없다 (폴더 규칙으로 대체)")
    func missingOrBroken() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "local_broken", "{ not json")
        try write(root, "local_array", "[1, 2]")
        let directory = DesktopSessionDirectory(root: root)
        #expect(directory.hint(forHostSession: "local_none") == nil)
        #expect(directory.hint(forHostSession: "local_broken") == nil)
        #expect(directory.hint(forHostSession: "local_array") == nil)
        #expect(directory.hint(forHostSession: "../acc/org/local_broken") == nil)
        #expect(DesktopSessionDirectory(root: root.appendingPathComponent("없음")).hint(forHostSession: "local_x") == nil)
    }

    @Test("부모 정보 파일이 없으면 아는 데까지만, 순환은 끊는다")
    func partialAndCycle() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "local_orphan", #"{"cliSessionId":"c-o","cwd":"/w/a","spawnedFrom":{"sessionId":"local_gone"}}"#)
        try write(root, "local_a", #"{"cliSessionId":"c-a","cwd":"/w/a","spawnedFrom":{"sessionId":"local_b"}}"#)
        try write(root, "local_b", #"{"cliSessionId":"c-b","cwd":"/w/b","spawnedFrom":{"sessionId":"local_a"}}"#)
        let directory = DesktopSessionDirectory(root: root)
        let orphan = try #require(directory.hint(forHostSession: "local_orphan"))
        #expect(orphan.ancestors.isEmpty)
        #expect(orphan.rootCwd == "/w/a")
        let cycle = try #require(directory.hint(forHostSession: "local_a"))
        #expect(cycle.ancestors == [SessionID("c-b")])
    }

    @Test("열려 있는 디렉토리 목록: 보관한 세션과 폴더 없는 세션은 빼고, 워크트리·띄운 세션은 원래(최상위) 폴더로 묶어 이름순")
    func openFolders() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "local_a", #"{"cwd":"/w/office","originCwd":"/w/office","isArchived":false,"lastActivityAt":1800000000000}"#)
        try write(root, "local_b", #"{"cwd":"/w/office/.claude/worktrees/x","spawnedFrom":{"sessionId":"local_a"},"lastActivityAt":1800000100000}"#)
        // 다른 폴더에서 띄운 세션은 띄운 쪽(최상위) 폴더로 셉니다
        try write(root, "local_g", #"{"cwd":"/w/elsewhere","spawnedFrom":{"sessionId":"local_a"}}"#)
        try write(root, org: "org2", "local_c", #"{"cwd":"/w/Blog"}"#)
        try write(root, "local_d", #"{"cwd":"/w/old","isArchived":true}"#)
        try write(root, "local_e", #"{"title":"폴더 없음"}"#)
        try write(root, "local_f", "{ 깨진 파일")
        let folders = DesktopSessionDirectory(root: root).openFolders()
        #expect(folders.map(\.path) == ["/w/Blog", "/w/office"])
        #expect(folders.map(\.name) == ["Blog", "office"])
        #expect(folders[1].sessions == 3)
        #expect(folders[1].lastActivity == Date(timeIntervalSince1970: 1_800_000_100))
        #expect(DesktopSessionDirectory(root: root.appendingPathComponent("없음")).openFolders().isEmpty)
    }

    @Test("정보 파일이 나중에 생기면 잠시 뒤 다시 찾는다")
    func lateFile() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = Clock()
        let directory = DesktopSessionDirectory(root: root, ttl: 10, missTTL: 2, now: { clock.now })
        #expect(directory.hint(forHostSession: "local_late") == nil)
        try write(root, "local_late", #"{"cliSessionId":"c","cwd":"/w/late","title":"늦게"}"#)
        #expect(directory.hint(forHostSession: "local_late") == nil)  // 아직 캐시
        clock.now = clock.now.addingTimeInterval(3)
        #expect(directory.hint(forHostSession: "local_late")?.title == "늦게")
    }
}

final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
