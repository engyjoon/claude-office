import Foundation

/// 말풍선과 상태 칩에 들어갈 문자열에서 비밀번호, 토큰처럼 보이는 값을 가립니다.
/// 표시 수준이 "상세"여도 항상 적용됩니다 (설계서 §7.4).
public enum Redactor {
    public static let mask = "<가림>"

    private struct Rule: @unchecked Sendable {
        let regex: Regex<AnyRegexOutput>
        let replace: @Sendable (Regex<AnyRegexOutput>.Match) -> String
    }

    private static let rules: [Rule] = [
        // URL 안의 계정 정보: https://user:pass@host
        Rule(regex: try! Regex(#"://[^/\s:@]+:[^/\s@]+@"#)) { _ in "://\(mask)@" },
        // Authorization: Bearer xxx
        Rule(regex: try! Regex(#"(?i)\bbearer\s+\S+"#)) { _ in "Bearer \(mask)" },
        // password=xxx, API_KEY: xxx … (구분자는 = 나 : 만. 빈칸은 아래 --flag 규칙에서만)
        Rule(regex: try! Regex(#"(?i)((?:password|passwd|pwd|token|secret|api[_-]?key|access[_-]?key|credential)[\w-]*["']?\s*[=:]\s*)("[^"]*"|'[^']*'|\S+)"#)) {
            match in
            (match.output[1].substring.map(String.init) ?? "") + mask
        },
        // --password xxx, --api-key xxx (플래그 꼴일 때만 빈칸 구분. 다음 낱말이 또 다른 플래그면 값이 아님)
        Rule(regex: try! Regex(#"(?i)((?:^|\s)--[\w-]*(?:password|passwd|token|secret|api[_-]?key|access[_-]?key|credential)[\w-]*\s+)("[^"]*"|'[^']*'|[^\s-]\S*)"#)) {
            match in
            (match.output[1].substring.map(String.init) ?? "") + mask
        },
        // curl -u user:pass, --user user:pass (값에 ':'가 있을 때만. `git push -u origin`은 그대로)
        Rule(regex: try! Regex(#"((?:^|\s)(?:-u|--user|--proxy-user)(?:\s+|=))(?:"[^"\s]*:[^"]*"|'[^'\s]*:[^']*'|[^\s:'"]+:\S+)"#)) {
            match in
            (match.output[1].substring.map(String.init) ?? "") + mask
        },
        // sshpass -p xxx / sshpass -p'xxx'
        Rule(regex: try! Regex(#"(\bsshpass\s+-p\s*)("[^"]*"|'[^']*'|\S+)"#)) {
            match in
            (match.output[1].substring.map(String.init) ?? "") + mask
        },
        // mysql -pxxx (mysql·mysqldump·mysqladmin 명령 안에서 붙여 쓴 꼴만. 다른 도구의 -p<값>(예: `mkdir -p`)은 건드리지 않음)
        Rule(regex: try! Regex(#"(\bmysql(?:dump|admin|import|check)?\b[^|;&\n]*?\s-p)(?!\s)("[^"]*"|'[^']*'|\S+)"#)) {
            match in
            (match.output[1].substring.map(String.init) ?? "") + mask
        },
        // Authorization: Basic xxx
        Rule(regex: try! Regex(#"(?i)(\bauthorization\s*[:=]\s*["']?basic\s+)[^\s"']+"#)) {
            match in
            (match.output[1].substring.map(String.init) ?? "") + mask
        },
        // 잘 알려진 키 접두사
        Rule(regex: try! Regex(#"\b(?:sk-[A-Za-z0-9_-]{8,}|gh[pousr]_[A-Za-z0-9]{16,}|xox[abpr]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16})"#)) { _ in mask },
        // 긴 hex / base64 덩어리 (경로가 걸리지 않도록 '/'는 빼고, 숫자가 섞인 경우만)
        Rule(regex: try! Regex(#"\b(?:[A-Fa-f0-9]{32,}|(?=[A-Za-z0-9+_-]*[0-9])[A-Za-z0-9+_-]{40,}={0,2})"#)) { _ in mask },
    ]

    public static func redact(_ text: String) -> String {
        var result = text
        for rule in rules {
            result = result.replacing(rule.regex) { rule.replace($0) }
        }
        return result
    }
}
