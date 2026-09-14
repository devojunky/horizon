import Foundation

/// What can go wrong talking to Claude, in classes that decide what happens next: the key and the request are the
/// user's to fix (no retry), a payload too large is the caller's to split, and the rest is retried with backoff.
public enum ClaudeError: Error, LocalizedError, Sendable, Equatable {
    case unauthorized
    case modelNotFound(String)
    case badRequest(String)
    case payloadTooLarge
    case rateLimited(retryAfter: TimeInterval?)
    case overloaded
    case server(status: Int, message: String)
    case network(String)
    case interrupted(String)
    case malformed(String)
    case exhausted(attempts: Int, last: String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized: "the API key is missing or was rejected"
        case .modelNotFound(let model): "Anthropic has no model named \(model)"
        case .badRequest(let message): "Anthropic rejected the request: \(message)"
        case .payloadTooLarge: "the request was too large for the model"
        case .rateLimited(let after): "Anthropic is rate limiting" + (after.map { String(format: ", try again in %.0f s", $0) } ?? "")
        case .overloaded: "Anthropic is overloaded right now"
        case .server(let status, let message): "Anthropic returned \(status)" + (message.isEmpty ? "" : ": \(message)")
        case .network(let why): "no connection (\(why))"
        case .interrupted(let why): "the connection dropped (\(why))"
        case .malformed(let why): "the reply could not be read: \(why)"
        case .exhausted(let attempts, let last): "gave up after \(attempts) attempts; last: \(last)"
        }
    }

    var isRetryable: Bool {
        switch self {
        case .rateLimited, .overloaded, .server, .network, .interrupted: true
        default: false
        }
    }
}

/// One HTTP exchange as the client sees it: the response head, then the body a line at a time as it arrives. The live
/// one is URLSession; tests script responses, dropouts and delays.
public struct ClaudeTransport: Sendable {
    public var send: @Sendable (URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, any Error>)
    public init(send: @escaping @Sendable (URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, any Error>)) { self.send = send }

    public static let live = ClaudeTransport { request in
        let (bytes, response) = try await ClaudeClient.session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClaudeError.malformed("not an HTTP response") }
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

/// The Messages API with structured output, streamed. Every call is retried on the failures that pass (a dropped
/// connection, a rate limit, an overload, a server error) with exponential backoff and the server's own Retry-After,
/// never on the ones that will not change (a bad key, a bad request, a payload too large). Cancellation stops
/// everything at once. No thinking is asked for: extraction is copying, and a thinking model spent its budget
/// thinking and answered with an empty structure one run in three.
public actor ClaudeClient {
    public struct Request: Sendable {
        public var system: String
        public var user: String
        /// JPEG pictures, sent base64 before the text.
        public var images: [Data]
        /// A JSON Schema object, as text, its properties in the order the model should write them.
        public var schema: String
        public var maxOutputTokens: Int
        public init(system: String, user: String, images: [Data] = [], schema: String, maxOutputTokens: Int) {
            self.system = system; self.user = user; self.images = images; self.schema = schema; self.maxOutputTokens = maxOutputTokens
        }
    }

    public struct Completion: Sendable, Equatable {
        public var text: String
        /// "end_turn" for a whole reply, "max_tokens" when the output budget cut it, "refusal" when the model declined.
        public var stopReason: String?
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

    public static let apiVersion = "2023-06-01"

    /// Five minutes between bytes (a long document keeps the model quiet before its first token), fifteen for the whole
    /// exchange; connectivity is our retries' business.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 900
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    public let configuration: ClaudeConfiguration
    private let transport: ClaudeTransport
    private let policy: Policy
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let log: @Sendable (String) -> Void

    public init(configuration: ClaudeConfiguration, transport: ClaudeTransport = .live, policy: Policy = Policy(),
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
            } catch let error as ClaudeError {
                guard error.isRetryable else { throw error }
                if attempt >= policy.attempts { throw ClaudeError.exhausted(attempts: attempt, last: error.localizedDescription) }
                let delay: TimeInterval
                if case .rateLimited(let after?) = error { delay = min(max(after, policy.baseDelay), policy.maxRetryAfter) }
                else { delay = policy.baseDelay * pow(2, Double(attempt - 1)) }
                log("claude: attempt \(attempt) failed (\(error.localizedDescription)); retrying in \(String(format: "%.1f", delay)) s")
                try await sleep(delay)
            }
        }
    }

    /// Whether the key and the model answer: one request for one word.
    public func probe() async throws -> String {
        let request = Request(system: "Answer with the single word OK.", user: "Are you there?", schema: ClaudeSchemas.render(.object([("answer", .string(nil))], required: ["answer"])), maxOutputTokens: 16)
        _ = try await stream(request)
        return "\(configuration.model.displayName) answered."
    }

    // MARK: One attempt

    private func attemptOnce(_ urlRequest: URLRequest, onText: @Sendable (String) async -> Void) async throws -> Completion {
        let (http, body): (HTTPURLResponse, AsyncThrowingStream<String, any Error>)
        do { (http, body) = try await transport.send(urlRequest) } catch { throw Self.mapTransport(error) }
        guard (200..<300).contains(http.statusCode) else { throw try await Self.failure(http, body, model: configuration.model.rawValue, log: log) }
        var text = "", stop: String?, ended = false
        var input = 0, cached = 0, output = 0
        do {
            for try await raw in body {
                let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard line.hasPrefix("data:") else { continue }   // "event:" lines, blanks and comments
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard let event = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { throw ClaudeError.malformed("an event was not JSON") }
                switch event["type"] as? String {
                case "message_start":
                    if let usage = (event["message"] as? [String: Any])?["usage"] as? [String: Any] {
                        input = usage["input_tokens"] as? Int ?? input
                        cached = usage["cache_read_input_tokens"] as? Int ?? cached
                    }
                case "content_block_delta":
                    if let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta", let piece = delta["text"] as? String, !piece.isEmpty {
                        text += piece
                        await onText(text)
                    }
                case "message_delta":
                    if let reason = (event["delta"] as? [String: Any])?["stop_reason"] as? String { stop = reason }
                    if let usage = event["usage"] as? [String: Any] {
                        output = usage["output_tokens"] as? Int ?? output
                        input = usage["input_tokens"] as? Int ?? input
                        cached = usage["cache_read_input_tokens"] as? Int ?? cached
                    }
                case "message_stop":
                    ended = true
                case "error":
                    let error = event["error"] as? [String: Any]
                    throw Self.apiError(status: 200, type: error?["type"] as? String ?? "", message: error?["message"] as? String ?? "unknown error", model: configuration.model.rawValue)
                default:
                    break   // message_stop's siblings: ping, content_block_start, content_block_stop
                }
                if ended { break }
            }
        } catch let error as ClaudeError {
            throw error
        } catch {
            throw Self.mapTransport(error, midStream: true)
        }
        guard ended || stop != nil else { throw ClaudeError.interrupted("the reply ended before it was complete") }
        return Completion(text: text, stopReason: stop, inputTokens: input, cachedTokens: cached, outputTokens: output, attempts: 0)
    }

    // MARK: Requests and errors

    func makeRequest(_ request: Request) throws -> URLRequest {
        var urlRequest = URLRequest(url: configuration.baseURL.appendingPathComponent("messages"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(configuration.apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // The schema's property order is the model's writing order, so the body is written by hand: JSONSerialization
        // would sort or shuffle it.
        let blocks = request.images.map { "{\"type\": \"image\", \"source\": {\"type\": \"base64\", \"media_type\": \"image/jpeg\", \"data\": \"\($0.base64EncodedString())\"}}" }
            + ["{\"type\": \"text\", \"text\": \(ClaudeSchemas.quote(request.user))}"]
        var outputConfig = "\"format\": {\"type\": \"json_schema\", \"schema\": \(request.schema)}"
        if configuration.model.acceptsEffort { outputConfig += ", \"effort\": \"medium\"" }
        let body = """
        {"model": \(ClaudeSchemas.quote(configuration.model.rawValue)), "max_tokens": \(request.maxOutputTokens), "stream": true, \
        "system": \(ClaudeSchemas.quote(request.system)), \
        "messages": [{"role": "user", "content": [\(blocks.joined(separator: ", "))]}], \
        "output_config": {\(outputConfig)}}
        """
        urlRequest.httpBody = Data(body.utf8)
        return urlRequest
    }

    /// A URLSession failure as one of ours. A cancelled request stays a cancellation.
    static func mapTransport(_ error: any Error, midStream: Bool = false) -> any Error {
        if error is CancellationError { return CancellationError() }
        if let url = error as? URLError {
            switch url.code {
            case .cancelled: return CancellationError()
            case .notConnectedToInternet, .internationalRoamingOff, .dataNotAllowed: return ClaudeError.network("offline")
            case .timedOut: return midStream ? ClaudeError.interrupted("timed out") : ClaudeError.network("timed out")
            case .networkConnectionLost: return ClaudeError.interrupted("connection lost")
            case .cannotFindHost, .dnsLookupFailed: return ClaudeError.network("cannot find api.anthropic.com")
            case .cannotConnectToHost: return ClaudeError.network("cannot connect")
            case .secureConnectionFailed, .serverCertificateUntrusted: return ClaudeError.network("secure connection failed")
            default: return midStream ? ClaudeError.interrupted(url.localizedDescription) : ClaudeError.network(url.localizedDescription)
            }
        }
        if let ours = error as? ClaudeError { return ours }
        return midStream ? ClaudeError.interrupted(error.localizedDescription) : ClaudeError.network(error.localizedDescription)
    }

    /// The error behind a non-2xx head, with the message Anthropic put in the body (read up to a limit).
    static func failure(_ http: HTTPURLResponse, _ body: AsyncThrowingStream<String, any Error>, model: String, log: @Sendable (String) -> Void = { _ in }) async throws -> ClaudeError {
        var text = ""
        do {
            for try await line in body {
                text += line
                if text.count > 65_536 { break }
            }
        } catch { /* the message is a courtesy */ }
        let error = ((try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any])?["error"] as? [String: Any]
        let message = error?["message"] as? String ?? String(text.prefix(300))
        let masked = message.replacingOccurrences(of: #"sk-[A-Za-z0-9_*-]+"#, with: "sk-…", options: .regularExpression)   // a rejected key is quoted back, in part
        log("claude: HTTP \(http.statusCode): \(masked.prefix(300))")   // the reason, where the classed error keeps only the class
        if http.statusCode == 429 {
            let after = (http.value(forHTTPHeaderField: "retry-after")).flatMap(Double.init)
            return .rateLimited(retryAfter: after)
        }
        return apiError(status: http.statusCode, type: error?["type"] as? String ?? "", message: message, model: model)
    }

    static func apiError(status: Int, type: String, message: String, model: String) -> ClaudeError {
        let lowered = message.lowercased()
        switch type {
        case "authentication_error", "permission_error": return .unauthorized
        case "overloaded_error": return .overloaded
        case "rate_limit_error": return .rateLimited(retryAfter: nil)
        case "not_found_error": return lowered.contains("model") ? .modelNotFound(model) : .badRequest(message)
        case "request_too_large": return .payloadTooLarge
        case "invalid_request_error": return lowered.contains("too long") || lowered.contains("too large") ? .payloadTooLarge : .badRequest(message)
        case "api_error": return .server(status: status, message: message)
        default: break
        }
        switch status {
        case 401, 403: return .unauthorized
        case 404: return lowered.contains("model") ? .modelNotFound(model) : .badRequest(message)
        case 413: return .payloadTooLarge
        case 400, 422: return lowered.contains("too long") || lowered.contains("too large") ? .payloadTooLarge : .badRequest(message)
        case 429: return .rateLimited(retryAfter: nil)
        case 529: return .overloaded
        case 200: return .interrupted(message)
        default: return .server(status: status, message: message)
        }
    }
}
