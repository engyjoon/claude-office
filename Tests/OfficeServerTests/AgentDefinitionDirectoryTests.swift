import Foundation
import OfficeCore
import Testing

@testable import OfficeServer

@Suite("에이전트 정의 파일 찾기")
struct AgentDefinitionDirectoryTests {
    func writeAgent(_ folder: URL, file: String, name: String, description: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "---\nname: \(name)\ndescription: \(description)\n---\n본문".write(
            to: folder.appendingPathComponent(file), atomically: true, encoding: .utf8)
    }

    @Test("행 폴더 → 위 폴더 → 사용자 폴더 순서로 찾고, 가까운 정의가 이긴다")
    func precedence() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let project = home.appendingPathComponent("Projects/asdn")
        let repo = project.appendingPathComponent("workspace/IPaSDN_web")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try writeAgent(home.appendingPathComponent(".claude/agents"), file: "backend-dev.md", name: "backend-dev", description: "사용자 백엔드")
        try writeAgent(home.appendingPathComponent(".claude/agents"), file: "web-dev.md", name: "web-dev", description: "사용자 웹")
        try writeAgent(project.appendingPathComponent(".claude/agents"), file: "web.md", name: "web-dev", description: "프로젝트 웹")
        let directory = AgentDefinitionDirectory(home: home)

        #expect(directory.definition(named: "web-dev", near: repo.path)?.description == "프로젝트 웹")
        #expect(directory.definition(named: "backend-dev", near: repo.path)?.description == "사용자 백엔드")
        #expect(directory.definition(named: "web-dev", near: nil)?.description == "사용자 웹")
        #expect(directory.definition(named: "없는-에이전트", near: repo.path) == nil)
        // 홈 밖 폴더에서도 사용자 폴더는 봅니다
        #expect(directory.definition(named: "backend-dev", near: "/elsewhere/project")?.description == "사용자 백엔드")
    }

    @Test("심볼릭 링크로 둔 정의 파일도 읽고, 파일 이름이 아니라 frontmatter의 이름으로 찾는다")
    func symlink() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let source = home.appendingPathComponent("Projects/asdn/projects/claude/agents")
        try writeAgent(source, file: "ios.md", name: "ios-dev", description: "iOS 개발 담당")
        let agents = home.appendingPathComponent(".claude/agents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: agents.appendingPathComponent("ios-link.md"), withDestinationURL: source.appendingPathComponent("ios.md"))
        let directory = AgentDefinitionDirectory(home: home)
        #expect(directory.definition(named: "ios-dev", near: nil)?.summary == "iOS 개발 담당")
    }

    @Test("읽은 결과는 ttl 동안 기억하고, 지나면 다시 읽는다")
    func cache() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let agents = home.appendingPathComponent(".claude/agents")
        try writeAgent(agents, file: "a.md", name: "a", description: "처음")
        let clock = TestClock()
        let directory = AgentDefinitionDirectory(home: home, ttl: 10, now: { clock.now })
        #expect(directory.definition(named: "a", near: nil)?.description == "처음")
        try writeAgent(agents, file: "a.md", name: "a", description: "고침")
        #expect(directory.definition(named: "a", near: nil)?.description == "처음")
        clock.advance(11)
        #expect(directory.definition(named: "a", near: nil)?.description == "고침")
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_000_000)
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}
