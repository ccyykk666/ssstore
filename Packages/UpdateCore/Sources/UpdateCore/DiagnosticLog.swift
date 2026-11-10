import Foundation

public enum DiagnosticLog {
    private static let secretNames = #"password(?:token)?|passwd|pwd|(?:access|refresh|id|session|auth)[_-]?token|token|appleid|email|username|user[-_ ]?id|account[-_ ]?id|phonenumber|authorization|(?:set[-_]?)?cookies?|x[-_]token|x[-_]apple[-_](?:amd(?:[-_](?:data|m))?|i[-_]md(?:[-_](?:m|rinfo))?|actionsignature)|kbsync|anisette|(?:host|root|device)?private[-_ ]?key|pairing(?:record|data|secret)|escrowbag|systembuid|hostid|udid|uniquedeviceid|directoryservices(?:identifier|id)|dspersonid|dsid|serialnumber"#
    private static let privateKey = regex(#"(?s)-----BEGIN [^-]*PRIVATE KEY-----.*?-----END [^-]*PRIVATE KEY-----"#)
    private static let xmlValue = regex(#"(?is)(<key>\s*(?:"# + secretNames + #")\s*</key>\s*)<(?:string|data|integer)>.*?</(?:string|data|integer)>"#)
    private static let header = regex(#"(?im)(\b(?:authorization|cookie|set-cookie|x-token|x-apple-(?:amd(?:-(?:data|m))?|i-md(?:-(?:m|rinfo))?|actionsignature))\s*:\s*).*$"#)
    private static let field = regex(#"(?i)(\b(?:"# + secretNames + #")\b["']?\s*[:=]\s*)(?:"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[^,\r\n;\]}]+)"#)
    private static let email = regex(#"(?i)[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#)
    private static let url = regex(#"(?i)\b(?:https?|itms-services)://[^\s<>"']+"#)

    public static func isSensitiveKey(_ key: String) -> Bool {
        let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
        if normalized == "xappleamdaction" { return false }
        return ["password", "passwd", "pwd", "passwordtoken", "token", "accesstoken", "refreshtoken", "idtoken", "sessiontoken", "authtoken",
            "appleid", "email", "username", "userid", "accountid", "phonenumber",
            "authorization", "cookie", "cookies", "setcookie", "xtoken", "xappleamd", "xappleamddata", "xappleamdm",
            "xappleimd", "xappleimdm", "xappleimdrinfo", "xappleactionsignature", "kbsync", "anisette",
            "privatekey", "hostprivatekey", "rootprivatekey", "deviceprivatekey", "pairingrecord", "pairingdata",
            "pairingsecret", "escrowbag", "systembuid", "hostid", "udid", "uniquedeviceid",
            "directoryservicesidentifier", "directoryservicesid", "dspersonid", "dsid", "serialnumber"].contains(normalized)
    }

    public static func shouldInclude(level: String, label: String, message: String) -> Bool {
        // Vapor probes optional dotenv files on startup. Keep actual permission/read errors.
        !(level == "debug" && label == "codes.vapor.application"
            && message.hasPrefix("Could not load .env") && message.contains("No such file or directory"))
    }

    public static func redact(_ message: String) -> String {
        var result = replace(privateKey, in: message, with: "<private key redacted>")
        result = replace(xmlValue, in: result, with: "$1<string><redacted></string>")
        result = replace(header, in: result, with: "$1<redacted>")
        // Replace URLs in reverse order so NSRanges stay valid for Unicode messages.
        for match in url.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let original = String(result[range])
            let trimmed = original.trimmingCharacters(in: CharacterSet(charactersIn: "),;]}"))
            let suffix = String(original.dropFirst(trimmed.count))
            if var components = URLComponents(string: trimmed), components.host != nil {
                components.user = nil
                components.password = nil
                components.query = nil
                components.fragment = nil
                result.replaceSubrange(range, with: (components.string ?? "<URL redacted>") + suffix)
            } else {
                result.replaceSubrange(range, with: "<URL redacted>")
            }
        }
        result = replace(field, in: result, with: "$1<redacted>")
        return replace(email, in: result, with: "<email redacted>")
    }

    public static func report(messages: [String], version: String, build: String,
                              system: String, device: String, capacity: Int, date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        let header = """
        ssstore \(version) (\(build))
        系统：\(system)
        设备：\(device)
        导出时间：\(formatter.string(from: date))
        日志：\(messages.count) 条（本次运行，最多保留最近 \(capacity) 条）
        """
        let body = messages.isEmpty ? "暂无日志" : messages.joined(separator: "\n\n")
        return redact(header + "\n\n" + body)
    }

    public static func errorDetails(_ error: Error) -> String {
        var current: NSError? = error as NSError
        var parts: [String] = []
        for _ in 0..<4 {
            guard let value = current else { break }
            parts.append("\(value.domain)(\(value.code)): \(value.localizedDescription)")
            if let failingURL = value.userInfo[NSURLErrorFailingURLErrorKey] as? URL {
                parts.append("url=\(failingURL.absoluteString)")
            }
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return redact(parts.joined(separator: " | "))
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)
    }
    private static func replace(_ pattern: NSRegularExpression, in text: String, with replacement: String) -> String {
        pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement)
    }
}
