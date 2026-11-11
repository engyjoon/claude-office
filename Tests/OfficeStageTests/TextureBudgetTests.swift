import Foundation
import Testing

@testable import OfficeStage

@Suite("텍스처 캐시 장부·층별 굽는 배율 (개선 10, 설계서 §8.3)")
struct TextureBudgetTests {
    typealias Ledger = TextureCacheLedger<String>

    @Test("장 수가 넘으면 통째로 비우지 않고 가장 오래 안 쓴 것부터 버림")
    func evictsLeastRecentlyUsed() {
        var ledger = Ledger(limits: .init(maxCount: 3, maxPixels: 1_000))
        #expect(ledger.insert("a", pixels: 10, scale: 2).evicted.isEmpty)
        #expect(ledger.insert("b", pixels: 10, scale: 2).evicted.isEmpty)
        #expect(ledger.insert("c", pixels: 10, scale: 2).evicted.isEmpty)
        // a를 다시 쓰면 b가 가장 오래됨
        ledger.touch("a")
        let result = ledger.insert("d", pixels: 10, scale: 2)
        #expect(result.stored)
        #expect(result.evicted == ["b"])
        #expect(ledger.count == 3)
        #expect(ledger.contains("a") && ledger.contains("c") && ledger.contains("d"))
        #expect(ledger.totalPixels == 30)
    }

    @Test("픽셀 합이 넘으면 들어갈 때까지 오래된 것부터 여럿 버림")
    func pixelBudget() {
        var ledger = Ledger(limits: .init(maxCount: 100, maxPixels: 100))
        _ = ledger.insert("a", pixels: 40, scale: 1)
        _ = ledger.insert("b", pixels: 40, scale: 1)
        _ = ledger.insert("c", pixels: 10, scale: 1)
        let result = ledger.insert("big", pixels: 80, scale: 1)
        #expect(result.stored)
        #expect(result.evicted == ["a", "b"])
        #expect(ledger.totalPixels == 90)
        #expect(ledger.count == 2)
    }

    @Test("혼자서 픽셀 상한을 넘는 텍스처는 담지 않고 다른 것도 버리지 않음")
    func oversizeIsNotStored() {
        var ledger = Ledger(limits: .init(maxCount: 10, maxPixels: 100))
        _ = ledger.insert("a", pixels: 50, scale: 2)
        let result = ledger.insert("huge", pixels: 101, scale: 2)
        #expect(!result.stored)
        #expect(result.evicted.isEmpty)
        #expect(ledger.contains("a"))
        #expect(!ledger.contains("huge"))
        #expect(ledger.totalPixels == 50)
    }

    @Test("같은 키를 다시 담으면 픽셀 합을 두 번 세지 않음")
    func reinsertReplaces() {
        var ledger = Ledger(limits: .init(maxCount: 10, maxPixels: 100))
        _ = ledger.insert("a", pixels: 30, scale: 1)
        _ = ledger.insert("a", pixels: 50, scale: 1)
        #expect(ledger.count == 1)
        #expect(ledger.totalPixels == 50)
    }

    @Test("화면 배율이 바뀌면 지금 쓰지 않는 배율의 텍스처를 모두 버림")
    func evictsOtherScales() {
        var ledger = Ledger()
        _ = ledger.insert("a@1", pixels: 10, scale: 1)
        _ = ledger.insert("b@2", pixels: 40, scale: 2)
        _ = ledger.insert("c@1", pixels: 10, scale: 1)
        let gone = ledger.evict(keepingScales: [2])
        #expect(Set(gone) == ["a@1", "c@1"])
        #expect(ledger.count == 1)
        #expect(ledger.totalPixels == 40)
        #expect(ledger.evict(keepingScales: [1, 2]).isEmpty)
    }

    @Test("모르는 키를 touch해도 아무 일 없음, 기본 상한은 400장·8Mi픽셀")
    func defaults() {
        var ledger = Ledger()
        ledger.touch("x")
        #expect(ledger.count == 0)
        #expect(TextureCacheLimits.standard == .init(maxCount: 400, maxPixels: 8 * 1_048_576))
    }

    @Test("기본 정책: 모든 층을 화면 배율로 (지금 동작 그대로)")
    func standardPolicy() {
        let policy = BakeScalePolicy.standard
        for layer in BakeLayer.allCases {
            #expect(policy.scale(for: layer, screen: 2) == 2)
            #expect(policy.scale(for: layer, screen: 1) == 1)
        }
        #expect(policy.scales(screen: 2) == [2])
        #expect(BakeScalePolicy.parse(nil) == .standard)
        #expect(BakeScalePolicy.parse("") == .standard)
    }

    @Test("측정용 환경 변수: 층=배율, 모르는 층·숫자 아님·범위 밖은 무시")
    func parse() {
        let policy = BakeScalePolicy.parse("background=1, furniture = 1.5,character=9,overlay=x,floor=1,=2,bogus")
        #expect(policy.overrides == [.background: 1, .furniture: 1.5])
        #expect(policy.scale(for: .background, screen: 2) == 1)
        #expect(policy.scale(for: .furniture, screen: 2) == 1.5)
        #expect(policy.scale(for: .character, screen: 2) == 2)
        #expect(policy.scales(screen: 2) == [1, 1.5, 2])
    }
}
