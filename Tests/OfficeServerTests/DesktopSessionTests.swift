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
        #expect(side.rootHostSession == "local_main" && side.rootTitle == "메인 작업" && side.rootIsOpen)
        #expect(!main.rootIsOpen && main.rootHostSession == nil)

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

    @Test("모두 다시 읽기: 수정 시각·크기가 그대로인 파일은 다시 파싱하지 않고, 바뀌거나 지운 파일은 반영 (M6(1))")
    func allRecordsReparsesOnlyChanged() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "local_a", #"{"cwd":"/w/office","title":"하나"}"#)
        try write(root, "local_b", #"{"cwd":"/w/blog"}"#)
        let directory = DesktopSessionDirectory(root: root)
        #expect(directory.allRecords().count == 2)
        #expect(directory.lastParsedCount == 2)

        #expect(directory.allRecords().count == 2)
        #expect(directory.lastParsedCount == 0)

        try write(root, "local_a", #"{"cwd":"/w/office","title":"둘로 바꿈"}"#)
        let file = root.appendingPathComponent("acc/org/local_a.json")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: file.path)
        let records = directory.allRecords()
        #expect(directory.lastParsedCount == 1)
        #expect(records.first { $0.localID == "local_a" }?.title == "둘로 바꿈")

        try FileManager.default.removeItem(at: root.appendingPathComponent("acc/org/local_b.json"))
        #expect(directory.allRecords().map(\.localID) == ["local_a"])
        #expect(directory.lastParsedCount == 0)
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

@Suite("데스크톱 세션 미리 출근 대상 (M5(5))")
struct DesktopResidentTests {
    func record(
        _ id: String, cli: String?, cwd: String = "/w/office", parent: String? = nil, archived: Bool = false, activity: Double,
        created: Double = 0
    ) -> DesktopSessionRecord {
        DesktopSessionRecord(
            localID: id, cliSessionID: cli, cwd: cwd, originCwd: nil, parentLocalID: parent, title: "제목 \(id)", isArchived: archived,
            lastActivity: Date(timeIntervalSince1970: activity), createdAt: Date(timeIntervalSince1970: created))
    }

    @Test("보관하지 않았고 CLI 세션 id가 있는 세션만, 오래 쉰 세션도 앉힌다")
    func filters() {
        let readAt = Date(timeIntervalSince1970: 2_000_000_000)
        let roll = DesktopResidents.roll(from: [
            record("local_open", cli: "c-open", activity: 1_000_000_000),  // 아주 오래 쉼
            record("local_archived", cli: "c-arch", archived: true, activity: 1_999_999_999),
            record("local_fresh", cli: nil, activity: 1_999_999_999),  // 아직 CLI 세션 없음
        ], readAt: readAt)
        #expect(roll.residents.map(\.session) == [SessionID("c-open")])
        #expect(roll.residents[0].hostSession == "local_open" && roll.residents[0].title == "제목 local_open")
        #expect(roll.residents[0].lastActivity == Date(timeIntervalSince1970: 1_000_000_000))
        #expect(roll.openHostSessions == ["local_open", "local_fresh"])
        #expect(roll.isReliable && roll.readAt == readAt)
        #expect(!DesktopResidents.roll(from: [], readAt: readAt).isReliable)
    }

    @Test("부모를 따라 조상과 최상위 폴더를 정하고, 최근에 활동한 행 → 부모 → 만든 순으로 놓는다")
    func ordering() {
        let roll = DesktopResidents.roll(from: [
            record("local_old", cli: "old", cwd: "/w/old", activity: 100),
            record("local_main", cli: "main", activity: 200, created: 1),
            record("local_side2", cli: "side2", cwd: "/w/office/.claude/worktrees/x", parent: "local_main", activity: 900, created: 3),
            record("local_side1", cli: "side1", parent: "local_main", activity: 300, created: 2),
            record("local_grand", cli: "grand", cwd: "/elsewhere", parent: "local_side1", activity: 250, created: 0),
            // 보관한 부모의 자식: 사무실에 부모가 없으니 혼자 행을 열지만, 조상과 최상위 폴더는 그대로 알려 줌
            record("local_gone", cli: "gone", cwd: "/w/gone", archived: true, activity: 50),
            record("local_orphan", cli: "orphan", cwd: "/w/gone/sub", parent: "local_gone", activity: 500),
        ], readAt: Date())
        #expect(roll.residents.map(\.session.raw) == ["main", "side1", "side2", "grand", "orphan", "old"])
        let byID = Dictionary(uniqueKeysWithValues: roll.residents.map { ($0.session.raw, $0) })
        #expect(byID["main"]?.ancestors == [])
        #expect(byID["grand"]?.ancestors == [SessionID("side1"), SessionID("main")])
        #expect(byID["grand"]?.rootCwd == "/w/office")
        #expect(byID["orphan"]?.ancestors == [SessionID("gone")] && byID["orphan"]?.rootCwd == "/w/gone")
    }

    @Test("본 때·응답 경계·응답 요약을 읽는다 (요약은 마지막 응답의 것일 때만, M6(4))")
    func parsesSeenAndSummary() throws {
        func parse(_ json: String) throws -> DesktopSessionRecord {
            try #require(DesktopSessionRecord.parse(Data(json.utf8), localID: "local_x"))
        }
        let blocked = try parse(#"""
            {"cliSessionId":"c","lastFocusedAt":1794191168772,"lastTurnEdgeAt":1794191338079,"lastAssistantUuid":"u2",
             "postTurnSummary":{"status_category":"blocked","needs_action":"A안과 B안 중 고르기","summarizes_uuid":"u2"}}
            """#)
        #expect(blocked.lastFocused == Date(timeIntervalSince1970: 1_794_191_168.772))
        #expect(blocked.lastTurnEdge == Date(timeIntervalSince1970: 1_794_191_338.079))
        #expect(blocked.replyRequest == true)
        let done = try parse(#"""
            {"cliSessionId":"c","lastAssistantUuid":"u2","postTurnSummaryFor":"u2",
             "postTurnSummary":{"status_category":"completed","needs_action":""}}
            """#)
        #expect(done.replyRequest == false)
        // 지난 응답의 요약, 결정할 것이 비어 있는 막힘, 요약 없음
        let stale = try parse(#"{"cliSessionId":"c","lastAssistantUuid":"u3","postTurnSummary":{"status_category":"blocked","needs_action":"x","summarizes_uuid":"u2"}}"#)
        #expect(stale.replyRequest == nil)
        let empty = try parse(#"{"cliSessionId":"c","lastAssistantUuid":"u2","postTurnSummary":{"status_category":"blocked","needs_action":"","summarizes_uuid":"u2"}}"#)
        #expect(empty.replyRequest == false)
        #expect(try parse(#"{"cliSessionId":"c"}"#).replyRequest == nil)
    }

    @Test("데스크톱 앱이 맨 앞이면 가장 최근에 연 세션을 지금 보는 세션으로 친다")
    func focusedResident() {
        func seen(_ id: String, _ cli: String, _ focused: Double?) -> DesktopSessionRecord {
            var value = record(id, cli: cli, activity: 100)
            value.lastFocused = focused.map { Date(timeIntervalSince1970: $0) }
            value.lastTurnEdge = Date(timeIntervalSince1970: 90)
            value.replyRequest = true
            return value
        }
        let list = [seen("local_a", "a", 50), seen("local_b", "b", 80), seen("local_c", "c", nil)]
        let active = DesktopResidents.roll(from: list, readAt: Date(), desktopAppActive: true)
        #expect(active.residents.filter(\.isFocused).map(\.session.raw) == ["b"])
        let byID = Dictionary(uniqueKeysWithValues: active.residents.map { ($0.session.raw, $0) })
        #expect(byID["a"]?.lastFocused == Date(timeIntervalSince1970: 50))
        #expect(byID["a"]?.lastTurnEdge == Date(timeIntervalSince1970: 90) && byID["a"]?.replyRequest == true)
        // 다른 앱이 앞에 있으면 아무도 지금 보고 있지 않음
        #expect(DesktopResidents.roll(from: list, readAt: Date()).residents.allSatisfy { !$0.isFocused })
    }

    @Test("정보 파일에서 만든 시각을 읽는다")
    func parsesCreatedAt() throws {
        let data = Data(#"{"cliSessionId":"c","cwd":"/w","createdAt":1794138247307,"lastActivityAt":1794138947335}"#.utf8)
        let record = try #require(DesktopSessionRecord.parse(data, localID: "local_x"))
        #expect(record.createdAt == Date(timeIntervalSince1970: 1_794_138_247.307))
    }
}
