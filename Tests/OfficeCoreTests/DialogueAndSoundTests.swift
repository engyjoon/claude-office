import Foundation
import Testing

@testable import OfficeCore

@Suite("대사")
struct DialogueTests {
    let book = DialogueBook.korean

    @Test("연출 엔진이 쓰는 키가 모두 있다")
    func keysExist() {
        let keys = [
            "arrive.lead", "leave.lead", "prompt.thinking", "delegate.lead", "delegate.member", "report.member",
            "report.lead", "permission.shell", "permission.tool", "permission.generic", "permission.denied", "error.tool",
            "error.repeated", "turn.done", "turn.failed", "shell.wait", "compact", "idle.chat",
        ]
        for key in keys {
            #expect(!(book.lines[key] ?? []).isEmpty, "\(key)")
        }
    }

    @Test("값이 없는 자리표시자가 있는 줄은 고르지 않는다")
    func placeholders() {
        var rng = SeededRandom(seed: 3)
        for _ in 0..<50 {
            let line = book.line("delegate.lead", ["member": "code-reviewer"], using: &rng)
            #expect(line != nil)
            #expect(line?.contains("{") == false)
        }
        #expect(book.line("permission.shell", [:], using: &rng) == nil)
        #expect(book.line("permission.shell", ["subject": "npm test"], using: &rng)?.contains("npm test") == true)
    }

    @Test("모든 대사는 해요체로 끝나거나 감탄·말줄임으로 끝난다")
    func politeTone() {
        let allowedEndings = ["요", "요!", "요~", "요?", "요…", "…", "…?", "!", "~"]
        for (key, lines) in book.lines {
            for line in lines {
                let ok = allowedEndings.contains { line.hasSuffix($0) }
                #expect(ok, "\(key): \(line)")
                #expect(!line.hasSuffix("해.") && !line.hasSuffix("야"), "반말: \(line)")
            }
        }
    }

    @Test("말풍선 표시 시간: 1.8초 + 글자당 60ms, 최대 6초")
    func bubbleDuration() {
        #expect(Bubble.timed(.speech, "다 했어요!").duration! == 1.8 + 0.06 * 6)
        #expect(Bubble.timed(.speech, String(repeating: "가", count: 200)).duration == 6)
    }
}

@Suite("효과음")
struct SoundTests {
    let allCues: [SoundCue] = [.knock, .inputWaiting, .turnComplete, .memberReport, .bubble(voice: 2, syllables: 3), .door, .error, .chatter, .footsteps, .typing]

    @Test("모든 효과음은 짧고(0.05~0.9초), 소리가 나며, -1...1 범위를 넘지 않는다")
    func renderAll() {
        var rng = SeededRandom(seed: 5)
        let renderer = SoundRenderer()
        for cue in allCues {
            let recipe = SoundLibrary.recipe(for: cue, using: &rng)
            #expect(recipe.duration >= 0.05 && recipe.duration <= 0.9, "\(cue): \(recipe.duration)")
            let samples = renderer.render(recipe)
            let peak = samples.map(abs).max() ?? 0
            #expect(peak > 0.02, "\(cue)는 너무 조용합니다: \(peak)")
            #expect(peak <= 1.0, "\(cue)가 범위를 넘습니다: \(peak)")
            #expect(samples.allSatisfy { $0.isFinite })
        }
    }

    @Test("직원 목소리가 높을수록 블립 음이 높다")
    func voices() {
        #expect(SoundLibrary.voicePitches == SoundLibrary.voicePitches.sorted())
        #expect(SoundLibrary.voicePitches.count == Appearance.voiceCount)
    }

    @Test("엔벨로프는 attack에서 최고점, 끝에서 0에 가깝다")
    func envelope() {
        #expect(abs(SoundRenderer.envelope(0.01, attack: 0.01, duration: 0.5, peak: 0.3) - 0.3) < 1e-9)
        #expect(SoundRenderer.envelope(0.5, attack: 0.01, duration: 0.5, peak: 0.3) < 0.001)
        #expect(SoundRenderer.envelope(0.6, attack: 0.01, duration: 0.5, peak: 0.3) == 0)
    }

    @Test("기본 설정: 잡담·발소리·타이핑은 꺼져 있고 음량은 35%")
    func defaults() {
        let settings = SoundSettings()
        #expect(settings.volume == 0.35)
        #expect(!settings.isEnabled(.chatter))
        #expect(!settings.isEnabled(.typing))
        #expect(settings.isEnabled(.approval))
        #expect(settings.isEnabled(.bubble))
    }

    @Test("정책: 음소거, 항목 끄기, 사무실이 안 보일 때 장식 소리, 집중 모드")
    func policyGates() {
        let now = Fixture.epoch
        var policy = SoundPolicy()
        let hidden = SoundContext(officeVisible: false)
        #expect(policy.decide(.knock, duration: 0.3, at: now, context: hidden) == .play(gain: 0.35))
        #expect(policy.decide(.door, duration: 0.3, at: now, context: hidden) == .skip(.officeHidden))
        #expect(policy.decide(.chatter, duration: 0.3, at: now, context: .init(officeVisible: true)) == .skip(.groupDisabled))
        #expect(policy.decide(.turnComplete, duration: 0.3, at: now, context: .init(officeVisible: true, focusModeActive: true)) == .skip(.focusMode))
        policy.settings.masterEnabled = false
        #expect(policy.decide(.inputWaiting, duration: 0.3, at: now, context: hidden) == .skip(.muted))
    }

    @Test("정책: 같은 항목 연속 재생 제한")
    func policyInterval() {
        let now = Fixture.epoch
        let visible = SoundContext(officeVisible: true)
        var policy = SoundPolicy()
        #expect(policy.decide(.bubble(voice: 0, syllables: 2), duration: 0.3, at: now, context: visible) == .play(gain: 0.35))
        #expect(policy.decide(.bubble(voice: 1, syllables: 2), duration: 0.3, at: now.addingTimeInterval(0.2), context: visible) == .skip(.tooSoon))
        #expect(policy.decide(.bubble(voice: 1, syllables: 2), duration: 0.3, at: now.addingTimeInterval(0.5), context: visible) == .play(gain: 0.35))
    }

    @Test("정책: 동시 재생 3개가 차면 더 중요한 소리만 자리를 넘겨받는다")
    func policyConcurrency() {
        let now = Fixture.epoch
        let visible = SoundContext(officeVisible: true)
        var policy = SoundPolicy()
        #expect(policy.decide(.bubble(voice: 0, syllables: 2), duration: 2, at: now, context: visible) != .skip(.busy))
        #expect(policy.decide(.door, duration: 2, at: now, context: visible) != .skip(.busy))
        #expect(policy.decide(.error, duration: 2, at: now, context: visible) != .skip(.busy))
        policy.settings.set(.footsteps, enabled: true)
        #expect(policy.decide(.footsteps, duration: 2, at: now, context: visible) == .skip(.busy))
        #expect(policy.decide(.knock, duration: 2, at: now, context: visible) == .play(gain: 0.35))
        // 재생이 끝나면 다시 자리가 생깁니다
        #expect(policy.decide(.footsteps, duration: 0.1, at: now.addingTimeInterval(3), context: visible) == .play(gain: 0.35))
    }
}
