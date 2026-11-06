import Foundation

/// 효과음을 데이터로 적은 레시피 (설계서 §11.5). 녹음 파일 없이 앱이 실행될 때 합성합니다.
public struct SoundRecipe: Hashable, Sendable {
    public enum Waveform: String, Hashable, Sendable {
        case sine, triangle, square
    }

    public enum FilterKind: String, Hashable, Sendable {
        case lowpass, highpass, bandpass
    }

    /// 주파수가 시간에 따라 바뀌는 지점 (지수 보간)
    public struct GlidePoint: Hashable, Sendable {
        public var time: Double
        public var frequency: Double
    }

    public struct Tone: Hashable, Sendable {
        public var start: Double
        public var frequency: Double
        public var duration: Double
        public var waveform: Waveform = .sine
        public var gain: Double = 0.3
        public var attack: Double = 0.004
        /// `start` 기준 시각에 도달할 주파수들
        public var glide: [GlidePoint] = []
    }

    public struct NoiseBurst: Hashable, Sendable {
        public var start: Double
        public var duration: Double
        public var filter: FilterKind
        public var frequency: Double
        public var q: Double
        public var gain: Double
    }

    public var tones: [Tone] = []
    public var noises: [NoiseBurst] = []

    public init(tones: [Tone] = [], noises: [NoiseBurst] = []) {
        self.tones = tones
        self.noises = noises
    }

    public var duration: Double {
        let toneEnd = tones.map { $0.start + $0.duration }.max() ?? 0
        let noiseEnd = noises.map { $0.start + $0.duration }.max() ?? 0
        return max(toneEnd, noiseEnd)
    }
}

/// 효과음 레시피 모음. 스타일 미리보기(docs/preview)의 Web Audio 시안과 같은 소리입니다.
public enum SoundLibrary {
    /// 말풍선 목소리 높이 5단계 (C5 ~ G5 부근)
    public static let voicePitches: [Double] = [440.0, 523.25, 587.33, 659.25, 783.99]

    public static func recipe(for cue: SoundCue, using rng: inout some RandomNumberGenerator) -> SoundRecipe {
        var recipe = SoundRecipe()
        switch cue {
        case .knock:
            for offset in [0.0, 0.17] {
                recipe.noises.append(.init(start: offset, duration: 0.06, filter: .bandpass, frequency: 750, q: 4, gain: 0.55))
                recipe.tones.append(.init(start: offset, frequency: 190, duration: 0.09, gain: 0.32, glide: [.init(time: 0.07, frequency: 190 * semitone(-3))]))
            }
        case .inputWaiting:
            recipe.tones += mallet(at: 0, frequency: 1046.5, duration: 0.22, gain: 0.22)
            recipe.tones += mallet(at: 0.11, frequency: 783.99, duration: 0.42, gain: 0.24)
        case .turnComplete:
            recipe.tones += mallet(at: 0, frequency: 1046.5, duration: 0.25)
            recipe.tones += mallet(at: 0.09, frequency: 1318.5, duration: 0.25)
            recipe.tones += mallet(at: 0.18, frequency: 1568.0, duration: 0.6, gain: 0.3)
        case .memberReport:
            recipe.tones += mallet(at: 0, frequency: 1318.5, duration: 0.22)
            recipe.tones += mallet(at: 0.09, frequency: 1568.0, duration: 0.45, gain: 0.26)
        case .bubble(let voice, let syllables):
            let base = voicePitches[min(max(voice, 0), voicePitches.count - 1)]
            recipe.tones.append(.init(start: 0, frequency: 1500, duration: 0.04, gain: 0.18, glide: [.init(time: 0.032, frequency: 1500 * semitone(-7))]))
            for index in 0..<min(max(syllables, 1), 6) {
                let step = Double(Int.random(in: -2...2, using: &rng))
                recipe.tones.append(.init(start: 0.07 + Double(index) * 0.085, frequency: base * semitone(step), duration: 0.07, waveform: .triangle, gain: 0.2, attack: 0.006))
            }
        case .door:
            for (offset, gain) in [(0.0, 0.26), (0.13, 0.15)] {
                recipe.tones.append(.init(start: offset, frequency: 1568, duration: 0.7, gain: gain))
                recipe.tones.append(.init(start: offset, frequency: 2093, duration: 0.55, gain: gain * 0.6))
                recipe.tones.append(.init(start: offset, frequency: 3136, duration: 0.25, gain: gain * 0.2))
            }
        case .error:
            recipe.tones.append(.init(start: 0, frequency: 660, duration: 0.38, waveform: .triangle, gain: 0.26, glide: [.init(time: 0.16, frequency: 430), .init(time: 0.34, frequency: 520)]))
        case .chatter:
            for index in 0..<3 {
                let step = Double(Int.random(in: -2...2, using: &rng))
                recipe.tones.append(.init(start: Double(index) * 0.1, frequency: 880 * semitone(step), duration: 0.06, waveform: .triangle, gain: 0.08))
            }
        case .footsteps:
            for offset in [0.0, 0.2] {
                recipe.noises.append(.init(start: offset, duration: 0.035, filter: .lowpass, frequency: 900, q: 1.2, gain: 0.35))
            }
        case .typing:
            var offset = 0.0
            for _ in 0..<5 {
                recipe.noises.append(.init(start: offset, duration: 0.018, filter: .highpass, frequency: 3200, q: 0.8, gain: 0.18))
                offset += 0.05 + Double.random(in: 0...0.06, using: &rng)
            }
        }
        return recipe
    }

    /// 실로폰/마림바 느낌: 기음 + 4배음(짧게) + 2배음
    static func mallet(at start: Double, frequency: Double, duration: Double, gain: Double = 0.28) -> [SoundRecipe.Tone] {
        [
            .init(start: start, frequency: frequency, duration: duration, gain: gain),
            .init(start: start, frequency: frequency * 4, duration: duration * 0.35, gain: gain * 0.18),
            .init(start: start, frequency: frequency * 2.01, duration: duration * 0.5, waveform: .triangle, gain: gain * 0.12),
        ]
    }

    static func semitone(_ steps: Double) -> Double {
        pow(2, steps / 12)
    }
}

/// 레시피를 PCM 샘플(모노, -1...1)로 합성합니다. 앱은 결과를 `AVAudioPCMBuffer`에 그대로 복사합니다.
public struct SoundRenderer: Sendable {
    public var sampleRate: Double

    public init(sampleRate: Double = 44_100) {
        self.sampleRate = sampleRate
    }

    public func render(_ recipe: SoundRecipe, noiseSeed: UInt64 = 1) -> [Float] {
        let tail = 0.03
        let count = Int(((recipe.duration + tail) * sampleRate).rounded(.up))
        var samples = [Float](repeating: 0, count: count)
        for tone in recipe.tones {
            addTone(tone, into: &samples)
        }
        var rng = SeededRandom(seed: noiseSeed)
        for noise in recipe.noises {
            addNoise(noise, into: &samples, rng: &rng)
        }
        // 겹친 소리가 찢어지지 않게 부드럽게 눌러 줍니다
        for index in samples.indices where abs(samples[index]) > 0.8 {
            samples[index] = Float(tanh(Double(samples[index])))
        }
        return samples
    }

    /// WebAudio의 exponentialRamp와 같은 모양: 0.0001에서 attack까지 올라갔다가 끝에서 0.0001로
    static func envelope(_ t: Double, attack: Double, duration: Double, peak: Double) -> Double {
        let floor = 0.0001
        guard t >= 0, t <= duration, peak > floor else { return 0 }
        if t < attack {
            return floor * pow(peak / floor, t / attack)
        }
        let decay = max(duration - attack, 1e-6)
        return peak * pow(floor / peak, (t - attack) / decay)
    }

    private func addTone(_ tone: SoundRecipe.Tone, into samples: inout [Float]) {
        let first = Int(tone.start * sampleRate)
        let length = Int(tone.duration * sampleRate)
        var phase = 0.0
        let points = [SoundRecipe.GlidePoint(time: 0, frequency: tone.frequency)] + tone.glide.sorted { $0.time < $1.time }
        for offset in 0..<length {
            let index = first + offset
            guard index < samples.count else { break }
            let t = Double(offset) / sampleRate
            let frequency = Self.frequency(at: t, points: points)
            phase += frequency / sampleRate
            phase -= phase.rounded(.down)
            let value: Double
            switch tone.waveform {
            case .sine: value = sin(2 * .pi * phase)
            case .triangle: value = 1 - 4 * abs(phase - 0.5)
            case .square: value = phase < 0.5 ? 0.6 : -0.6
            }
            samples[index] += Float(value * Self.envelope(t, attack: tone.attack, duration: tone.duration, peak: tone.gain))
        }
    }

    static func frequency(at t: Double, points: [SoundRecipe.GlidePoint]) -> Double {
        guard let last = points.last else { return 440 }
        if t >= last.time { return last.frequency }
        for (from, to) in zip(points, points.dropFirst()) where t < to.time {
            let span = max(to.time - from.time, 1e-6)
            let ratio = (t - from.time) / span
            return from.frequency * pow(to.frequency / from.frequency, ratio)
        }
        return last.frequency
    }

    private func addNoise(_ noise: SoundRecipe.NoiseBurst, into samples: inout [Float], rng: inout SeededRandom) {
        var filter = Biquad(kind: noise.filter, frequency: noise.frequency, q: noise.q, sampleRate: sampleRate)
        let first = Int(noise.start * sampleRate)
        let length = Int(noise.duration * sampleRate)
        for offset in 0..<length {
            let index = first + offset
            guard index < samples.count else { break }
            let t = Double(offset) / sampleRate
            let filtered = filter.process(Double(rng.nextSignedUnit()))
            samples[index] += Float(filtered * Self.envelope(t, attack: 0.002, duration: noise.duration, peak: noise.gain))
        }
    }
}

/// RBJ 오디오 EQ 쿡북의 2차 필터
struct Biquad {
    private var b0 = 0.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    private var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

    init(kind: SoundRecipe.FilterKind, frequency: Double, q: Double, sampleRate: Double) {
        let w0 = 2 * Double.pi * min(frequency, sampleRate * 0.45) / sampleRate
        let alpha = sin(w0) / (2 * max(q, 0.0001))
        let cosine = cos(w0)
        let a0 = 1 + alpha
        switch kind {
        case .lowpass:
            b0 = (1 - cosine) / 2
            b1 = 1 - cosine
            b2 = (1 - cosine) / 2
        case .highpass:
            b0 = (1 + cosine) / 2
            b1 = -(1 + cosine)
            b2 = (1 + cosine) / 2
        case .bandpass:
            b0 = alpha
            b1 = 0
            b2 = -alpha
        }
        b0 /= a0
        b1 /= a0
        b2 /= a0
        a1 = -2 * cosine / a0
        a2 = (1 - alpha) / a0
    }

    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1
        x1 = x
        y2 = y1
        y1 = y
        return y
    }
}
