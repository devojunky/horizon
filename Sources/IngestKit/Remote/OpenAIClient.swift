import Foundation

/// Reading and planning through OpenAI instead of Apple's models: the user's own key and their choice of model.
public struct OpenAIConfiguration: Sendable, Equatable {
    public var apiKey: String
    public var model: String
    public var baseURL: URL
    public static let defaultModel = "gpt-5-mini"
    public init(apiKey: String, model: String = OpenAIConfiguration.defaultModel, baseURL: URL = URL(string: "https://api.openai.com/v1")!) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? OpenAIConfiguration.defaultModel : model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.baseURL = baseURL
    }
}

/// What can go wrong talking to OpenAI, in classes that decide what happens next: the key and the request are the
/// user's to fix (no retry), a payload too large is the caller's to split, and the rest is retried with backoff.
public enum OpenAIError: Error, LocalizedError, Sendable, Equatable {
    case unauthorized
    case modelNotFound(String)
    case badRequest(String)
    case payloadTooLarge
    case rateLimited(retryAfter: TimeInterval?)
    case server(status: Int, message: String)
    case network(String)
    case interrupted(String)
    case malformed(String)
    case exhausted(attempts: Int, last: String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized: "OpenAI rejected the API key"
        case .modelNotFound(let model): "OpenAI has no model named \(model)"
        case .badRequest(let message): "OpenAI rejected the request: \(message)"
        case .payloadTooLarge: "the request was too large for the model"
        case .rateLimited(let after): "OpenAI is rate limiting" + (after.map { String(format: ", try again in %.0f s", $0) } ?? "")
        case .server(let status, let message): "OpenAI returned \(status)" + (message.isEmpty ? "" : ": \(message)")
        case .network(let why): "no connection to OpenAI: \(why)"
        case .interrupted(let why): "the connection to OpenAI dropped: \(why)"
        case .malformed(let why): "OpenAI's reply could not be read: \(why)"
        case .exhausted(let attempts, let last): "gave up after \(attempts) attempts; last: \(last)"
        }
    }

    var isRetryable: Bool {
        switch self {
        case .rateLimited, .server, .network, .interrupted: true
        default: false
        }
    }
}

/// One HTTP exchange as the client sees it: the response head, then the body a line at a time as it arrives. The live
/// one is URLSession; tests script responses, dropouts and delays.
public struct OpenAITransport: Sendable {
    public var send: @Sendable (URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, any Error>)
    public init(send: @escaping @Sendable (URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, any Error>)) { self.send = send }

    public static let live = OpenAITransport { request in
        let (bytes, response) = try await OpenAIClient.session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw OpenAIError.malformed("not an HTTP response") }
        let lines = AsyncThrowingStream<String, any Error> { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines { continuation.yield(line) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (http, lines)
    }
}

/// Chat Completions with strict structured output, streamed. Every call is retried on the failures that pass
/// (a dropped connection, a rate limit, a server error) with exponential backoff and the server's own Retry-After,
/// never on the ones that will not change (a bad key, a bad request, a payload too large). Cancellation stops
/// everything at once.
public actor OpenAIClient {
    public struct Request: Sendable {
        public var system: String
        public var user: String
        /// PNG pages, sent as data URLs.
        public var images: [Data]
        public var schemaName: String
        /// A JSON Schema object, as text, in OpenAI's strict form.
        public var schema: String
        public var maxOutputTokens: Int
        public init(system: String, user: String, images: [Data] = [], schemaName: String, schema: String, maxOutputTokens: Int) {
            self.system = system; self.user = user; self.images = images; self.schemaName = schemaName; self.schema = schema; self.maxOutputTokens = maxOutputTokens
        }
    }

    public struct Completion: Sendable, Equatable {
        public var text: String
        /// "stop" for a whole reply, "length" when the output budget cut it.
        public var finishReason: String?
        public var inputTokens: Int
        public var cachedTokens: Int
        public var outputTokens: Int
        public var attempts: Int
    }

    public struct Policy: Sendable {
        public var attempts = 4
        public var baseDelay: TimeInterval = 0.5
        public var maxRetryAfter: TimeInterval = 30
        public init() {}
    }

    /// Five minutes between bytes (a reasoning model says nothing while it thinks, and a long document can take it
    /// past a minute), fifteen for the whole exchange; connectivity is our retries' business.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 900
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    public let configuration: OpenAIConfiguration
    private let transport: OpenAITransport
    private let policy: Policy
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let log: @Sendable (String) -> Void

    public init(configuration: OpenAIConfiguration, transport: OpenAITransport = .live, policy: Policy = Policy(),
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.configuration = configuration; self.transport = transport; self.policy = policy; self.sleep = sleep; self.log = log
    }

    /// Streams one structured reply. `onText` receives the whole text so far after every delta (a retry starts it
    /// over from nothing, so a caller never sees a duplicated prefix).
    public func stream(_ request: Request, onText: @escaping @Sendable (String) async -> Void = { _ in }) async throws -> Completion {
        let urlRequest = try makeRequest(request)
        var attempt = 0
        while true {
            attempt += 1
            try Task.checkCancellation()
            do {
                var completion = try await attemptOnce(urlRequest, onText: onText)
                completion.attempts = attempt
                return completion
            } catch let error as OpenAIError {
                guard error.isRetryable else { throw error }
                if attempt >= policy.attempts { throw OpenAIError.exhausted(attempts: attempt, last: error.localizedDescription) }
                let delay: TimeInterval
                if case .rateLimited(let after?) = error { delay = min(max(after, policy.baseDelay), policy.maxRetryAfter) }
                else { delay = policy.baseDelay * pow(2, Double(attempt - 1)) }
                log("openai: attempt \(attempt) failed (\(error.localizedDescription)); retrying in \(String(format: "%.1f", delay)) s")
                try await sleep(delay)
            }
        }
    }

    /// Whether the key and the model are usable: one cheap request for the model's own record.
    public func probe() async throws -> String {
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent("models/\(configuration.model)"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        let (http, body): (HTTPURLResponse, AsyncThrowingStream<String, any Error>)
        do { (http, body) = try await transport.send(request) } catch { throw Self.mapTransport(error) }
        guard (200..<300).contains(http.statusCode) else { throw try await Self.failure(http, body, model: configuration.model, log: log) }
        return "\(configuration.model) is available"
    }

    // MARK: One attempt

    private func attemptOnce(_ urlRequest: URLRequest, onText: @Sendable (String) async -> Void) async throws -> Completion {
        let (http, body): (HTTPURLResponse, AsyncThrowingStream<String, any Error>)
        do { (http, body) = try await transport.send(urlRequest) } catch { throw Self.mapTransport(error) }
        guard (200..<300).contains(http.statusCode) else { throw try await Self.failure(http, body, model: configuration.model, log: log) }
        var text = "", finish: String?, sawDone = false
        var input = 0, cached = 0, output = 0
        do {
            for try await raw in body {
                let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard line.hasPrefix("data:") else { continue }   // blank lines and comments
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { sawDone = true; break }
                guard let event = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { throw OpenAIError.malformed("an event was not JSON") }
                if let error = event["error"] as? [String: Any] { throw Self.apiError(status: http.statusCode, message: error["message"] as? String ?? "unknown error", model: configuration.model) }
                if let choice = (event["choices"] as? [[String: Any]])?.first {
                    if let delta = choice["delta"] as? [String: Any], let content = delta["content"] as? String, !content.isEmpty {
                        text += content
                        await onText(text)
                    }
                    if let reason = choice["finish_reason"] as? String { finish = reason }
                }
                if let usage = event["usage"] as? [String: Any] {
                    input = usage["prompt_tokens"] as? Int ?? input
                    output = usage["completion_tokens"] as? Int ?? output
                    cached = (usage["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int ?? cached
                }
            }
        } catch let error as OpenAIError {
            throw error
        } catch {
            throw Self.mapTransport(error, midStream: true)
        }
        guard sawDone || finish != nil else { throw OpenAIError.interrupted("the reply ended before it was complete") }
        return Completion(text: text, finishReason: finish, inputTokens: input, cachedTokens: cached, outputTokens: output, attempts: 0)
    }

    // MARK: Requests and errors

    func makeRequest(_ request: Request) throws -> URLRequest {
        var urlRequest = URLRequest(url: configuration.baseURL.appendingPathComponent("chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        guard let schema = try? JSONSerialization.jsonObject(with: Data(request.schema.utf8)) else { throw OpenAIError.badRequest("the schema is not valid JSON") }
        let content: Any
        if request.images.isEmpty {
            content = request.user
        } else {
            content = [["type": "text", "text": request.user]] + request.images.map { data in
                ["type": "image_url", "image_url": ["url": "data:image/png;base64," + data.base64EncodedString(), "detail": "high"]]
            }
        }
        let body: [String: Any] = [
            "model": configuration.model,
            "stream": true,
            "stream_options": ["include_usage": true],
            "max_completion_tokens": request.maxOutputTokens,
            "messages": [["role": "system", "content": request.system], ["role": "user", "content": content]],
            "response_format": ["type": "json_schema", "json_schema": ["name": request.schemaName, "strict": true, "schema": schema]],
        ]
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }

    /// A URLSession failure as one of ours. A cancelled request stays a cancellation.
    static func mapTransport(_ error: any Error, midStream: Bool = false) -> any Error {
        if error is CancellationError { return CancellationError() }
        if let url = error as? URLError {
            switch url.code {
            case .cancelled: return CancellationError()
            case .notConnectedToInternet: return OpenAIError.network("offline")
            case .timedOut: return midStream ? OpenAIError.interrupted("timed out") : OpenAIError.network("timed out")
            case .networkConnectionLost: return OpenAIError.interrupted("connection lost")
            case .cannotFindHost, .dnsLookupFailed: return OpenAIError.network("cannot find api.openai.com")
            case .cannotConnectToHost: return OpenAIError.network("cannot connect")
            case .secureConnectionFailed, .serverCertificateUntrusted: return OpenAIError.network("secure connection failed")
            default: return midStream ? OpenAIError.interrupted(url.localizedDescription) : OpenAIError.network(url.localizedDescription)
            }
        }
        if let ours = error as? OpenAIError { return ours }
        return midStream ? OpenAIError.interrupted(error.localizedDescription) : OpenAIError.network(error.localizedDescription)
    }

    /// The error behind a non-2xx head, with the message OpenAI put in the body (read up to a limit).
    static func failure(_ http: HTTPURLResponse, _ body: AsyncThrowingStream<String, any Error>, model: String, log: @Sendable (String) -> Void = { _ in }) async throws -> OpenAIError {
        var text = ""
        do {
            for try await line in body {
                text += line
                if text.count > 65_536 { break }
            }
        } catch { /* the message is a courtesy */ }
        let message = ((try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]).flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
            ?? String(text.prefix(300))
        let masked = message.replacingOccurrences(of: #"sk-[A-Za-z0-9_*-]+"#, with: "sk-…", options: .regularExpression)   // a rejected key is quoted back, in part
        log("openai: HTTP \(http.statusCode): \(masked.prefix(300))")   // the reason, where the classed error keeps only the class
        if http.statusCode == 429 {
            let after = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(Double.init)
            return .rateLimited(retryAfter: after)
        }
        return apiError(status: http.statusCode, message: message, model: model)
    }

    static func apiError(status: Int, message: String, model: String) -> OpenAIError {
        let lowered = message.lowercased()
        if lowered.contains("context length") || lowered.contains("context_length") || lowered.contains("too large") || lowered.contains("maximum context") { return .payloadTooLarge }
        if lowered.contains("api key") || lowered.contains("invalid_api_key") || lowered.contains("unauthorized") { return .unauthorized }   // an error event mid-stream carries no status
        if status == 200 { return lowered.contains("rate limit") ? .rateLimited(retryAfter: nil) : .interrupted(message) }
        switch status {
        case 401, 403: return .unauthorized
        case 404: return lowered.contains("model") ? .modelNotFound(model) : .badRequest(message)
        case 413: return .payloadTooLarge
        case 400, 422: return .badRequest(message)
        case 429: return .rateLimited(retryAfter: nil)
        default: return .server(status: status, message: message)
        }
    }
}
