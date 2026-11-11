import OfficeCore
import OfficeStage

/// 무대 상태를 담아 두는 상자. AppModel이 매 프레임 갱신하고 씬이 읽습니다 (둘 다 메인 스레드).
final class StageStore {
    /// 화면에 보일 사람만 고르는 층과 그 무대 (M5(1))
    var floor = OfficeFloor()
    var stage: Stage { floor.stage }
    /// 말풍선·상태 칩에 보여줄 내용 수준 (설정의 표시 수준)
    var privacy: PrivacyLevel = .detailed
    /// 사무실 조명 (M6(6)). 바꿀 때는 씬의 `setLighting`을 거쳐 크로스페이드합니다.
    var lighting: Lighting = .day
    /// 시스템 "대비 증가" (M6(7)): 상태 칩·배지·명패 테두리를 진하게
    var highContrast = false
}
