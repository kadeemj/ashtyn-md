import Foundation

/// Incremental Server-Sent-Events assembler. Push lines in (in any chunking),
/// complete events come out. Tolerates CR, comments, and unknown fields.
struct SSEDecoder {
    struct Event: Equatable, Sendable {
        var name: String?
        var data: String
    }

    private var currentName: String?
    private var currentData: [String] = []

    /// Feed one line (without its trailing newline). Returns a complete event
    /// when the line terminates one.
    mutating func feed(line rawLine: String) -> Event? {
        var line = rawLine
        if line.hasSuffix("\r") { line.removeLast() }

        if line.isEmpty {
            // Blank line dispatches the pending event.
            guard !currentData.isEmpty || currentName != nil else { return nil }
            let event = Event(name: currentName, data: currentData.joined(separator: "\n"))
            currentName = nil
            currentData = []
            return event.data.isEmpty && event.name == nil ? nil : event
        }
        if line.hasPrefix(":") { return nil }

        let field: Substring
        let value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            var v = line[line.index(after: colon)...]
            if v.hasPrefix(" ") { v = v.dropFirst() }
            value = v
        } else {
            field = line[...]
            value = ""
        }
        switch field {
        case "event": currentName = String(value)
        case "data": currentData.append(String(value))
        default: break // id, retry, unknown fields: ignored
        }
        return nil
    }

    /// Any unterminated trailing event (streams that end without a blank line).
    mutating func flush() -> Event? {
        feed(line: "")
    }
}

/// Newline-delimited JSON: each non-empty line is one JSON object.
enum NDJSONDecoder {
    static func object(fromLine line: String) -> [String: Any]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// Shared HTTP plumbing for the provider adapters.
enum ProviderHTTP {
    static func jsonRequest(
        url: URL, method: String = "POST", headers: [String: String], body: [String: Any]?
    ) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 60
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    /// Maps a non-2xx response to a typed provider error, parsing rate-limit
    /// headers when present.
    static func errorForResponse(_ response: HTTPURLResponse, bodyText: String) -> AIProviderError {
        if response.statusCode == 429 {
            let retryAfter = response.value(forHTTPHeaderField: "retry-after").flatMap(Double.init)
            return .rateLimited(retryAfterSeconds: retryAfter)
        }
        // Try to surface the provider's error message without dumping bodies.
        var message = String(bodyText.prefix(300))
        if let data = bodyText.data(using: .utf8),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if let error = object["error"] as? [String: Any],
               let detail = error["message"] as? String {
                message = detail
            }
        }
        return .httpError(status: response.statusCode, message: message)
    }
}
