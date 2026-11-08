import Foundation

/// 훅 스크립트(curl)가 보내는 아주 작은 HTTP/1.1 요청
public struct HTTPRequest: Hashable, Sendable {
    public var method: String
    public var path: String
    /// 소문자 헤더 이름 → 값
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, headers: [String: String], body: Data) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }
}

public enum HTTPParseResult: Hashable, Sendable {
    /// 아직 다 받지 못함
    case incomplete
    case complete(HTTPRequest)
    case tooLarge
    case invalid(String)
}

/// 버퍼에 쌓인 바이트에서 요청 하나를 읽습니다. Content-Length 본문만 지원합니다 (curl --data-binary).
public enum HTTPRequestParser {
    public static let maxHeaderBytes = 16 * 1024

    public static func parse(_ data: Data, maxBodyBytes: Int) -> HTTPParseResult {
        let bytes = [UInt8](data)
        guard let headerEnd = find([13, 10, 13, 10], in: bytes) else {
            return bytes.count > maxHeaderBytes ? .invalid("헤더가 너무 깁니다") : .incomplete
        }
        guard headerEnd <= maxHeaderBytes else { return .invalid("헤더가 너무 깁니다") }
        let headerText = String(decoding: bytes[0..<headerEnd], as: UTF8.self)
        var lines = headerText.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { return .invalid("요청 줄 형식이 올바르지 않습니다") }

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return .invalid("헤더 형식이 올바르지 않습니다") }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        if headers["transfer-encoding"] != nil { return .invalid("chunked 전송은 지원하지 않습니다") }

        let length: Int
        if let text = headers["content-length"] {
            guard let value = Int(text), value >= 0 else { return .invalid("Content-Length가 올바르지 않습니다") }
            length = value
        } else {
            length = 0
        }
        guard length <= maxBodyBytes else { return .tooLarge }
        let bodyStart = headerEnd + 4
        guard bytes.count - bodyStart >= length else { return .incomplete }
        let body = Data(bytes[bodyStart..<bodyStart + length])
        return .complete(HTTPRequest(method: String(requestLine[0]), path: String(requestLine[1]), headers: headers, body: body))
    }

    private static func find(_ pattern: [UInt8], in bytes: [UInt8]) -> Int? {
        guard bytes.count >= pattern.count else { return nil }
        for index in 0...(bytes.count - pattern.count) where bytes[index] == pattern[0] {
            if Array(bytes[index..<index + pattern.count]) == pattern { return index }
        }
        return nil
    }
}

/// 받은 훅 하나
public struct HookDelivery: Hashable, Sendable {
    public let body: Data
    /// 훅 스크립트가 보낸 TERM_PROGRAM
    public let term: String?
    /// 훅 스크립트가 보낸 데스크톱 앱 세션 id (`CLAUDE_CODE_HOST_SESSION_ID`, `local_…`). 형식이 맞을 때만.
    public let hostSession: String?
    public let receivedAt: Date

    public init(body: Data, term: String?, hostSession: String? = nil, receivedAt: Date) {
        self.body = body
        self.term = term
        self.hostSession = hostSession
        self.receivedAt = receivedAt
    }
}

/// 로컬 훅 서버의 요청 검증 규칙 (설계서 §12.1)
public struct HookRequestPolicy: Sendable {
    public enum Decision: Hashable, Sendable {
        case accept(body: Data, term: String?, hostSession: String?)
        case reject(status: Int, reason: String)
    }

    public static let path = "/v1/hook"
    public let token: String
    public var maxBodyBytes = 1024 * 1024

    public init(token: String) {
        self.token = token
    }

    public func evaluate(_ request: HTTPRequest) -> Decision {
        // 브라우저가 보낸 요청(CSRF, DNS 리바인딩)은 Origin 헤더가 붙습니다. curl은 붙이지 않습니다.
        if request.headers["origin"] != nil { return .reject(status: 403, reason: "Origin 헤더가 있는 요청은 받지 않습니다") }
        guard request.path == Self.path else { return .reject(status: 404, reason: "알 수 없는 경로입니다") }
        guard request.method == "POST" else { return .reject(status: 405, reason: "POST만 받습니다") }
        guard Self.constantTimeEquals(request.headers["x-office-token"] ?? "", token) else {
            return .reject(status: 401, reason: "토큰이 맞지 않습니다")
        }
        guard (request.headers["content-type"] ?? "").lowercased().hasPrefix("application/json") else {
            return .reject(status: 415, reason: "JSON만 받습니다")
        }
        guard !request.body.isEmpty else { return .reject(status: 400, reason: "본문이 비어 있습니다") }
        let term = request.headers["x-office-term"].flatMap { $0.isEmpty || $0 == "unknown" ? nil : $0 }
        let host = request.headers["x-office-host-session"].flatMap { Self.isHostSessionID($0) ? $0 : nil }
        return .accept(body: request.body, term: term, hostSession: host)
    }

    /// 데스크톱 앱 세션 id 형식 (`local_` + 영숫자·하이픈). 파일 경로에 쓰므로 그 밖의 값은 버립니다.
    public static func isHostSessionID(_ value: String) -> Bool {
        guard value.hasPrefix("local_"), value.count > 6, value.count <= 80 else { return false }
        return value.dropFirst(6).allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" }
    }

    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        var difference = UInt8(a.count == b.count ? 0 : 1)
        for index in 0..<max(a.count, b.count) {
            difference |= (index < a.count ? a[index] : 0) ^ (index < b.count ? b[index] : 0)
        }
        return difference == 0
    }

    /// 실행할 때마다 새로 만드는 토큰 (32바이트, 16진수 64자)
    public static func makeToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
    }
}

public enum HTTPResponse {
    public static func serialize(status: Int, body: String = "") -> Data {
        let reason: String
        switch status {
        case 202: reason = "Accepted"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        case 413: reason = "Payload Too Large"
        case 415: reason = "Unsupported Media Type"
        default: reason = "Error"
        }
        let bodyData = Data(body.utf8)
        var text = "HTTP/1.1 \(status) \(reason)\r\n"
        text += "Content-Type: text/plain; charset=utf-8\r\n"
        text += "Content-Length: \(bodyData.count)\r\n"
        text += "Connection: close\r\n\r\n"
        return Data(text.utf8) + bodyData
    }
}
