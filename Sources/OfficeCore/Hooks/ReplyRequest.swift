import Foundation

/// 응답이 사용자의 답을 바라며 끝났는지 어림합니다 (M6(4), 설계서 §6.2 "답변 필요").
///
/// `Stop` 훅의 `last_assistant_message`에서 마지막 문단만 봅니다. 본문은 판정에만 쓰고 저장하지 않습니다.
/// - 마지막 문장이 물음표(`?`, `？`)로 끝나면 질문 ("A안과 B안 중 어느 쪽으로 할까요?")
/// - 마지막 문단에 결정·답을 바라는 말이 있으면 ("골라 주세요", "정해 주세요", "알려 주세요", "Should I …")
/// "화면에서 확인해 주세요"처럼 확인만 부탁하는 말은 답변 필요로 보지 않습니다 (응답 끝에 흔히 붙음).
/// 데스크톱 세션은 데스크톱 앱의 응답 요약(`ResidentSession.replyRequest`)이 오면 그 판정을 따릅니다.
public enum ReplyRequest {
    /// 마지막 문단에서 보는 최대 글자 수 (끝에서부터)
    static let tailLength = 240

    /// 결정·답을 바라는 말 (소문자로 비교)
    static let phrases = [
        "골라 주세요", "골라주세요", "정해 주세요", "정해주세요", "알려 주세요", "알려주세요", "답해 주세요", "답해주세요",
        "선택해 주세요", "선택해주세요", "결정해 주세요", "결정해주세요", "말씀해 주세요", "말씀해주세요", "주시겠어요",
        "할까요", "될까요", "드릴까요", "볼까요", "갈까요",
        "let me know which", "let me know if you'd like", "should i ", "would you like", "do you want me to", "which option",
    ]

    public static func asksUser(_ message: String?) -> Bool {
        guard let message, let paragraph = lastParagraph(message) else { return false }
        let sentence = paragraph.trimmingCharacters(in: trailingNoise)
        if sentence.hasSuffix("?") || sentence.hasSuffix("？") { return true }
        let lower = paragraph.lowercased()
        return phrases.contains { lower.contains($0) }
    }

    /// 문장 끝에 붙는 꾸밈 (마크다운 강조·괄호·따옴표·공백)
    static let trailingNoise = CharacterSet(charactersIn: "*_`~)]」』\"'”’ ").union(.whitespacesAndNewlines)

    /// 마지막 문단 (빈 줄로 나눔, 코드 블록 울타리는 건너뜀). 끝에서 `tailLength`자까지.
    static func lastParagraph(_ message: String) -> String? {
        let paragraphs = message
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("```") }
        guard let last = paragraphs.last else { return nil }
        return String(last.suffix(tailLength))
    }
}
