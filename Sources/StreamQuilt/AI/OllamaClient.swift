import Foundation

/// Minimal Ollama /api/chat client for the emotion engine.
///
/// POST {base}/api/chat with {"model":..., "stream":false, "format":"json",
/// "messages":[system,user]}. URLSession runs on a background delegate queue
/// with a 20s request timeout; completion hops to the main queue by default.
/// Tolerant JSON: takes the first `{` to last `}` substring of the reply
/// content and parses that with JSONSerialization.
public final class OllamaClient {
    public let baseURL: URL
    public var model: String
    public var timeout: TimeInterval = 20

    private let session: URLSession

    public init(base: String = "http://127.0.0.1:11434", model: String = "gemma4:e4b-mlx") {
        baseURL = URL(string: base) ?? URL(string: "http://127.0.0.1:11434")!
        self.model = model
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        let queue = OperationQueue()
        queue.name = "lkg.ollama-client"
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: config, delegate: nil, delegateQueue: queue)
    }

    /// Chat with strict-JSON expectation. Completion receives the parsed JSON
    /// object (nil on transport error, timeout, or unparseable content).
    public func chat(system: String, user: String,
                     completionQueue: DispatchQueue? = .main,
                     completion: @escaping ([String: Any]?) -> Void) {
        let url = baseURL.appendingPathComponent("api/chat")
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "stream": false,
            "format": "json",
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            completionQueue.asyncIfNeeded { completion(nil) }
            return
        }
        req.httpBody = data
        let t0 = Date()
        session.dataTask(with: req) { data, _, error in
            let parsed = Self.parseContent(data: data)
            if parsed == nil {
                print("[ollama] chat failed: \(error?.localizedDescription ?? "unparseable response") (\(String(format: "%.1f", Date().timeIntervalSince(t0)))s)")
            }
            completionQueue.asyncIfNeeded { completion(parsed) }
        }.resume()
    }

    /// Tolerant extraction: first `{` to last `}` of message.content.
    static func parseContent(data: Data?) -> [String: Any]? {
        guard let data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = obj["message"] as? [String: Any],
              let content = message["content"] as? String,
              let open = content.firstIndex(of: "{"),
              let close = content.lastIndex(of: "}"), close >= open else { return nil }
        let jsonText = String(content[open...close])
        guard let jsonData = jsonText.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        else { return nil }
        return parsed
    }
}

private extension Optional where Wrapped == DispatchQueue {
    func asyncIfNeeded(_ block: @escaping () -> Void) {
        if let q = self { q.async(execute: block) } else { block() }
    }
}
