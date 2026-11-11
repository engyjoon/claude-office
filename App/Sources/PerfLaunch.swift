import AppKit
import QuartzCore
import SpriteKit

/// 측정 전용 실행 설정 (개선 10 2단계, 설계서 §8.3). 환경 변수로만 켜고, 평소 동작은 그대로입니다.
///
/// 새 빌드를 설치된 앱과 나란히 띄워 잴 때 설치된 앱의 것을 건드리지 않고, 창 조작 없이 상태를 만들려고 둡니다.
/// - `CLAUDE_OFFICE_PERF=1`: 알림 센터를 건드리지 않습니다(켤 때·끌 때 지우기, 권한 묻기, 보내기 모두 안 함 — 같은 번들 ID의
///   설치된 앱 알림을 지우지 않게). 미니 위치와 첫 실행 표시를 저장하지 않습니다.
/// - `CLAUDE_OFFICE_PERF_SCENE=menubar|mini|office`: 켤 때의 화면. 미니 켜기/끄기는 저장하지 않고 이번 실행에만 씁니다.
/// - `CLAUDE_OFFICE_DRAWABLE_SCALE=1`: SpriteKit 뷰의 그림판(drawable)을 화면 배율 대신 이 배율로 (실험, 글자까지 흐려짐).
enum PerfLaunch {
    private static let environment = ProcessInfo.processInfo.environment

    /// 측정 실행인지 (`CLAUDE_OFFICE_PERF=1`, UserDefaults의 `debug.perfProbe`로는 켜지 않음)
    static let isMeasuring = environment["CLAUDE_OFFICE_PERF"] == "1"

    enum Scene: String {
        /// 메뉴바만 (미니 끔)
        case menubar
        /// 미니 사무실만
        case mini
        /// 사무실 창 열기 (미니는 사무실 창이 열려 있으면 숨음)
        case office
    }

    /// 켤 때의 화면 (측정 실행일 때만)
    static let scene: Scene? = isMeasuring ? environment["CLAUDE_OFFICE_PERF_SCENE"].flatMap(Scene.init) : nil

    /// 그림판 배율 실험값 (측정 실행일 때만, 0.5~4)
    static let drawableScale: CGFloat? = {
        guard isMeasuring, let text = environment["CLAUDE_OFFICE_DRAWABLE_SCALE"], let value = Double(text), (0.5...4).contains(value)
        else { return nil }
        return CGFloat(value)
    }()
}

extension SKView {
    /// 그림판 배율 실험 (`CLAUDE_OFFICE_DRAWABLE_SCALE`). 값이 없으면 아무것도 하지 않습니다.
    func applyDrawableScaleExperiment() {
        guard let scale = PerfLaunch.drawableScale, let layer = layer as? CAMetalLayer, layer.contentsScale != scale else { return }
        layer.contentsScale = scale
    }
}
