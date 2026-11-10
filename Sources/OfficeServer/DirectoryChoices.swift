import Foundation

/// 디렉토리 고르기 항목 하나 ("모두" 또는 디렉토리 하나).
/// 사무실 창 오른쪽 패널의 디렉토리 드롭다운과 미니 사무실 오른쪽 클릭 메뉴 "디렉토리 ▸"(M6(18))가 같이 씁니다.
public struct DirectoryChoice: Hashable, Sendable {
    /// "claude-office · 메인 2 · 7명", 닫힌 디렉토리는 "claude-office (닫힘)"
    public var title: String
    /// nil이면 "모두"
    public var path: String?
    /// 지금 고른 항목
    public var isSelected: Bool
    /// 데스크톱 앱에서 닫혔지만 지금 골라 둔 디렉토리
    public var isClosed: Bool

    public init(title: String, path: String?, isSelected: Bool, isClosed: Bool = false) {
        self.title = title
        self.path = path
        self.isSelected = isSelected
        self.isClosed = isClosed
    }

    /// 항목 목록: "모두"를 맨 앞에, 그 뒤로 열린 디렉토리(받은 순서 그대로), 닫혔지만 골라 둔 디렉토리는 맨 끝.
    /// - Parameters:
    ///   - open: 데스크톱 앱에 열린 디렉토리
    ///   - selected: 고른 디렉토리 경로 (nil이면 모두)
    ///   - total: 사무실 전체 인원 ("모두 · 9명")
    ///   - headcount: 그 디렉토리에서 지금 사무실에 있는 메인 수와 사람 수
    public static func list(
        open: [DesktopFolder], selected: String?, total: Int, headcount: (String) -> (mains: Int, people: Int)
    ) -> [DirectoryChoice] {
        var folders = open
        if let selected, !folders.contains(where: { $0.path == selected }) {
            folders.append(DesktopFolder(path: selected, sessions: 0))
        }
        let all = DirectoryChoice(title: total > 0 ? "모두 · \(total)명" : "모두", path: nil, isSelected: selected == nil)
        return [all] + folders.map { folder in
            let closed = !open.contains { $0.path == folder.path }
            let count = headcount(folder.path)
            var text = folder.name
            if closed { text += " (닫힘)" }
            if count.people > 0 { text += count.mains > 1 ? " · 메인 \(count.mains) · \(count.people)명" : " · \(count.people)명" }
            return DirectoryChoice(title: text, path: folder.path, isSelected: folder.path == selected, isClosed: closed)
        }
    }
}
