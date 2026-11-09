import AppKit
import OfficeCore
import OfficeStage
import SpriteKit

/// 사무실 장면(SKView) 안 캐릭터를 VoiceOver에 보여 주는 접근성 요소 (M6(7)).
///
/// - 요소는 사람마다 한 번 만들어 다시 씁니다(VoiceOver 커서가 같은 요소에 머물도록). 매 프레임 만들지 않습니다.
/// - 이름·위치·상태는 VoiceOver가 물을 때만 그 자리에서 셉니다(`accessibilityLabel()`, `accessibilityFrame()`).
///   그래서 그리기 빈도(M6(1))에는 아무 일도 더하지 않습니다.
/// - 사람이 오가거나 "+N"이 바뀌면 장면이 `layoutChanged`를, 상태 글자가 바뀌면 그 요소에 `titleChanged`를 보냅니다(VoiceOver가 켜져 있을 때만).
final class CharacterAccessibilityElement: NSAccessibilityElement {
    let agent: AgentID
    private weak var scene: OfficeScene?

    init(agent: AgentID, scene: OfficeScene) {
        self.agent = agent
        self.scene = scene
        super.init()
    }

    private var row: RosterRow? { scene?.accessibilityRow?(agent) }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityRoleDescription() -> String? { "직원" }
    override func accessibilityLabel() -> String? { row.map(AccessibilityText.agent) }
    override func accessibilityValue() -> Any? { AccessibilityText.agentValue(selected: scene?.selectedAgent == agent) }
    override func accessibilityHelp() -> String? {
        guard let scene else { return nil }
        if scene.isBand { return "누르면 사무실 창을 열고 이 직원을 골라요." }
        return AccessibilityText.agentHint(focusLabel: row?.focusLabel)
    }
    override func isAccessibilitySelected() -> Bool { scene?.selectedAgent == agent }
    override func isAccessibilityFocused() -> Bool { scene?.keyboardFocusedAgent == agent }
    override func accessibilityParent() -> Any? { scene?.view }
    override func accessibilityFrame() -> NSRect { scene?.accessibilityScreenFrame(of: agent) ?? .zero }

    /// 누르기 = 고르기 (마우스 한 번 누르기와 같음)
    override func accessibilityPerformPress() -> Bool {
        guard let scene else { return false }
        scene.onSelect?(agent)
        return true
    }

    /// 확인(기본 동작) = 그 세션으로 이동 (더블클릭·Return과 같음)
    override func accessibilityPerformConfirm() -> Bool {
        guard let scene, row?.focusLabel != nil else { return false }
        scene.onActivate?(agent)
        return true
    }

    /// 메뉴 보기 (VO+Shift+M, M6(11)): 미니에서만 그 직원 메뉴(오른쪽 클릭과 같음)
    override func accessibilityPerformShowMenu() -> Bool {
        guard let scene, scene.isBand, let show = scene.onAccessibilityMenu else { return false }
        return show(agent)
    }

    /// 사무실 창 직원에는 메뉴가 없으므로 메뉴 보기 동작을 내놓지 않습니다
    override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
        if selector == #selector(accessibilityPerformShowMenu) { return scene?.isBand == true }
        return super.isAccessibilitySelectorAllowed(selector)
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard let focus = row?.focusLabel else { return nil }
        return [NSAccessibilityCustomAction(name: AccessibilityText.moveActionName(focusLabel: focus)) { [weak self] in
            self?.accessibilityPerformConfirm() ?? false
        }]
    }
}

/// 읽기만 하는 글자 요소: 행 끝 "+N", 통째로 숨긴 행
final class SceneTextAccessibilityElement: NSAccessibilityElement {
    var text: String
    var frame: () -> NSRect
    private weak var scene: OfficeScene?

    init(text: String, scene: OfficeScene, frame: @escaping () -> NSRect) {
        self.text = text
        self.scene = scene
        self.frame = frame
        super.init()
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityLabel() -> String? { text }
    override func accessibilityValue() -> Any? { text }
    override func accessibilityParent() -> Any? { scene?.view }
    override func accessibilityFrame() -> NSRect { frame() }
}

extension OfficeScene {
    /// 행 끝 "+N"과 숨긴 행 요약 (사람마다 요소는 `characterElement(for:)`)
    struct AccessibilityExtras {
        var more: [TeamID: SceneTextAccessibilityElement] = [:]
        var hiddenRows: SceneTextAccessibilityElement?
    }

    /// VoiceOver가 읽는 순서대로 요소 (행 → 책상, 행 끝에 "+N", 맨 끝에 숨긴 행)
    func accessibilityElements() -> [NSAccessibilityElement] {
        let stage = store.stage
        let rows = SceneNavigation.rows(stage)
        var result: [NSAccessibilityElement] = []
        var keptMore = Set<TeamID>()
        for ids in rows {
            for id in ids where characterNodeExists(id) {
                result.append(characterElement(for: id))
            }
            guard let team = ids.first.flatMap({ stage.actors[$0]?.agent.teamID }), let count = stage.hiddenCounts[team], count > 0,
                let row = stage.layout.row(for: team)
            else { continue }
            keptMore.insert(team)
            let text = AccessibilityText.hidden(count: count, folder: stage.teams[team]?.name ?? "")
            let center = MapPoint(row.endX + 26, row.deskY - 18)
            let element = accessibilityExtras.more[team] ?? SceneTextAccessibilityElement(text: text, scene: self) { [weak self] in
                self?.accessibilityScreenFrame(map: MapRect(center.x - 18, center.y - 11, 36, 22)) ?? .zero
            }
            element.text = text
            accessibilityExtras.more[team] = element
            result.append(element)
        }
        accessibilityExtras.more = accessibilityExtras.more.filter { keptMore.contains($0.key) }
        if let summary = accessibilityHiddenRows?() {
            let element = accessibilityExtras.hiddenRows ?? SceneTextAccessibilityElement(text: summary, scene: self) { [weak self] in
                guard let view = self?.view else { return .zero }
                return NSAccessibility.screenRect(fromView: view, rect: NSRect(x: 0, y: 0, width: view.bounds.width, height: 28))
            }
            element.text = summary
            accessibilityExtras.hiddenRows = element
            result.append(element)
        } else {
            accessibilityExtras.hiddenRows = nil
        }
        return result
    }

    func characterElement(for id: AgentID) -> CharacterAccessibilityElement {
        if let element = characterElements[id] { return element }
        let element = CharacterAccessibilityElement(agent: id, scene: self)
        characterElements[id] = element
        return element
    }

    /// 지도 좌표(y 아래로) 사각형 → 화면 좌표
    func accessibilityScreenFrame(map rect: MapRect) -> NSRect {
        guard let view else { return .zero }
        let height = store.stage.layout.height
        let a = convert(CGPoint(x: rect.x, y: height - rect.y), from: world)
        let b = convert(CGPoint(x: rect.maxX, y: height - rect.maxY), from: world)
        let p = view.convert(a, from: self), q = view.convert(b, from: self)
        let local = NSRect(x: min(p.x, q.x), y: min(p.y, q.y), width: abs(q.x - p.x), height: abs(q.y - p.y))
        return NSAccessibility.screenRect(fromView: view, rect: local)
    }
}

/// 사무실 장면을 담는 SKView의 접근성 (사무실 창·미니 공통): 장면 하나를 묶음으로, 그 안에 사람마다 요소
class AccessibleSKView: SKView {
    var officeScene: OfficeScene? { scene as? OfficeScene }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? {
        guard let scene = officeScene else { return "사무실" }
        let stage = scene.store.stage
        let people = stage.actors.count
        return AccessibilityText.scene(rows: stage.layout.rows.count, people: people, mini: scene.isBand)
    }
    override func accessibilityHelp() -> String? {
        officeScene?.isBand == true ? "직원을 누르면 사무실 창이 열려요." : AccessibilityText.sceneHint
    }
    override func accessibilityChildren() -> [Any]? {
        officeScene?.accessibilityElements()
    }
    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        guard let elements = officeScene?.accessibilityElements() else { return self }
        // 겹쳐 있으면 앞(화면 아래쪽)에 선 사람: 화면 좌표는 y가 위로 증가하므로 아래쪽 = minY가 작은 쪽
        let hits = elements.filter { NSPointInRect(point, $0.accessibilityFrame()) }
        return hits.min { $0.accessibilityFrame().minY < $1.accessibilityFrame().minY } ?? self
    }
    override var accessibilityFocusedUIElement: Any? {
        guard let scene = officeScene, let id = scene.keyboardFocusedAgent else { return self }
        return scene.characterElement(for: id)
    }
}
