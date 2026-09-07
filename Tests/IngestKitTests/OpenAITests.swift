import Foundation
import Testing
@testable import IngestKit

/// The OpenAI client against a scripted transport: what it sends, how it reads a stream, and what it does when the
/// stream drops, the server balks, or the key is wrong. No network.
struct OpenAIClientTests {
    /// One scripted exchange: a status with headers and body lines, or a failure before any head arrives.
    enum Exchange: Sendable {
        case reply(status: Int, headers: [String: String] = [:], lines: [String], dropAfter: Int? = nil)
        case fail(URLError.Code)
    }

    final class Script: @unchecked Sendable {
        var exchanges: [Exchange]
        var requests: [URLRequest] = []
        var sleeps: [TimeInterval] = []
        var logs: [String] = []
        init(_ exchanges: [Exchange]) { self.exchanges = exchanges }

        var transport: OpenAITransport {
            OpenAITransport { [self] request in
                requests.append(request)
                guard !exchanges.isEmpty else { throw URLError(.badServerResponse) }
                switch exchanges.removeFirst() {
                case .fail(let code): throw URLError(code)
                case .reply(let status, let headers, let lines, let dropAfter):
                    let http = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
                    let stream = AsyncThrowingStream<String, any Error> { continuation in
                        for (i, line) in lines.enumerated() {
                            if let dropAfter, i == dropAfter { continuation.finish(throwing: URLError(.networkConnectionLost)); return }
                            continuation.yield(line)
                        }
                        continuation.finish()
                    }
                    return (http, stream)
                }
            }
        }

        func client(model: String = "gpt-5-mini") -> OpenAIClient {
            OpenAIClient(configuration: OpenAIConfiguration(apiKey: "sk-test", model: model), transport: transport,
                         sleep: { [self] s in sleeps.append(s) }, log: { [self] in logs.append($0) })
        }
    }

    static func event(_ content: String? = nil, finish: String? = nil, usage: (Int, Int)? = nil) -> String {
        var choice: [String: Any] = ["index": 0, "delta": content.map { ["content": $0] } ?? [:]]
        choice["finish_reason"] = finish ?? NSNull()
        var object: [String: Any] = ["id": "x", "object": "chat.completion.chunk", "choices": [choice]]
        if let usage { object["usage"] = ["prompt_tokens": usage.0, "completion_tokens": usage.1, "prompt_tokens_details": ["cached_tokens": 3]] }
        return "data: " + String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
    static let request = OpenAIClient.Request(system: "sys", user: "read this", schemaName: "chunk_extraction", schema: OpenAISchemas.extraction, maxOutputTokens: 100)
    static let happy = [event("{\"a\":"), "", event(" 1}"), event(nil, finish: "stop"), event(nil, usage: (120, 8)), "data: [DONE]"]

    @Test func streamsTheTextAndReadsTheUsage() async throws {
        let script = Script([.reply(status: 200, lines: Self.happy)])
        let seen = Script([])
        let completion = try await script.client().stream(Self.request) { text in seen.logs.append(text) }
        #expect(completion.text == "{\"a\": 1}" && completion.finishReason == "stop" && completion.inputTokens == 120 && completion.outputTokens == 8 && completion.cachedTokens == 3)
        #expect(seen.logs == ["{\"a\":", "{\"a\": 1}"] && completion.attempts == 1)
    }

    @Test func sendsAStrictStructuredStreamingRequest() async throws {
        let script = Script([.reply(status: 200, lines: Self.happy)])
        var request = Self.request
        request.images = [Data([0x89, 0x50])]
        _ = try await script.client().stream(request)
        let sent = try #require(script.requests.first)
        #expect(sent.url?.absoluteString == "https://api.openai.com/v1/chat/completions" && sent.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        let body = try #require(try JSONSerialization.jsonObject(with: sent.httpBody!) as? [String: Any])
        #expect(body["model"] as? String == "gpt-5-mini" && body["stream"] as? Bool == true && body["max_completion_tokens"] as? Int == 100)
        let format = try #require(body["response_format"] as? [String: Any])
        let schema = try #require(format["json_schema"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema" && schema["strict"] as? Bool == true && schema["name"] as? String == "chunk_extraction")
        let messages = try #require(body["messages"] as? [[String: Any]])
        let parts = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(parts[0]["type"] as? String == "text" && parts[1]["type"] as? String == "image_url")
        #expect(((parts[1]["image_url"] as? [String: Any])?["url"] as? String)?.hasPrefix("data:image/png;base64,") == true)
    }

    @Test func aDroppedStreamIsRetriedFromTheStart() async throws {
        let script = Script([.reply(status: 200, lines: Self.happy, dropAfter: 2), .reply(status: 200, lines: Self.happy)])
        let seen = Script([])
        let completion = try await script.client().stream(Self.request) { text in seen.logs.append(text) }
        #expect(completion.text == "{\"a\": 1}" && completion.attempts == 2 && script.sleeps == [0.5])
        #expect(seen.logs.last == "{\"a\": 1}" && seen.logs.first == "{\"a\":")   // the second attempt started over
        #expect(script.logs.contains { $0.contains("connection lost") && $0.contains("retrying") })
    }

    @Test func aStreamThatEndsWithoutADoneIsInterruptedAndRetried() async throws {
        let script = Script([.reply(status: 200, lines: [Self.event("{")]), .reply(status: 200, lines: Self.happy)])
        let completion = try await script.client().stream(Self.request)
        #expect(completion.attempts == 2 && script.logs.contains { $0.contains("ended before it was complete") })
    }

    @Test func rateLimitsWaitForRetryAfterAndServerErrorsBackOff() async throws {
        let script = Script([.reply(status: 429, headers: ["Retry-After": "7"], lines: ["{\"error\":{\"message\":\"slow down\"}}"]),
                             .reply(status: 503, lines: ["upstream"]), .reply(status: 200, lines: Self.happy)])
        let completion = try await script.client().stream(Self.request)
        #expect(completion.attempts == 3 && script.sleeps == [7, 1.0])
        // A Retry-After beyond reason is capped.
        let capped = Script([.reply(status: 429, headers: ["Retry-After": "600"], lines: []), .reply(status: 200, lines: Self.happy)])
        _ = try await capped.client().stream(Self.request)
        #expect(capped.sleeps == [30])
    }

    @Test func aBadKeyOrModelOrRequestIsNotRetried() async throws {
        let bad = Script([.reply(status: 401, lines: ["{\"error\":{\"message\":\"Incorrect API key\"}}"])])
        await #expect(throws: OpenAIError.unauthorized) { try await bad.client().stream(Self.request) }
        #expect(bad.requests.count == 1 && bad.sleeps.isEmpty)
        let missing = Script([.reply(status: 404, lines: ["{\"error\":{\"message\":\"The model `gpt-9` does not exist\"}}"])])
        await #expect(throws: OpenAIError.modelNotFound("gpt-9")) { try await missing.client(model: "gpt-9").stream(Self.request) }
        let request = Script([.reply(status: 400, lines: ["{\"error\":{\"message\":\"Invalid schema\"}}"])])
        await #expect(throws: OpenAIError.badRequest("Invalid schema")) { try await request.client().stream(Self.request) }
    }

    @Test func aRequestTooLargeIsItsOwnError() async throws {
        let script = Script([.reply(status: 400, lines: ["{\"error\":{\"message\":\"This model's maximum context length is 128000 tokens\"}}"])])
        await #expect(throws: OpenAIError.payloadTooLarge) { try await script.client().stream(Self.request) }
        #expect(Extractor.isContextOverflow(OpenAIError.payloadTooLarge))
    }

    @Test func persistentFailuresGiveUpAfterFourAttempts() async throws {
        let script = Script([.fail(.notConnectedToInternet), .fail(.timedOut), .reply(status: 500, lines: []), .fail(.networkConnectionLost)])
        await #expect(throws: OpenAIError.exhausted(attempts: 4, last: "the connection to OpenAI dropped: connection lost")) { try await script.client().stream(Self.request) }
        #expect(script.sleeps == [0.5, 1.0, 2.0] && script.requests.count == 4)
    }

    @Test func cancellationIsNotRetried() async throws {
        let script = Script([.fail(.cancelled), .reply(status: 200, lines: Self.happy)])
        await #expect(throws: CancellationError.self) { try await script.client().stream(Self.request) }
        #expect(script.requests.count == 1)
    }

    @Test func aMidStreamErrorEventIsReported() async throws {
        let script = Script([.reply(status: 200, lines: [Self.event("{"), "data: {\"error\":{\"message\":\"Incorrect API key\"}}"])])
        await #expect(throws: OpenAIError.unauthorized) { try await script.client().stream(Self.request) }
    }

    @Test func theProbeReadsTheModelRecord() async throws {
        let ok = Script([.reply(status: 200, lines: ["{\"id\":\"gpt-5-mini\"}"])])
        #expect(try await ok.client().probe() == "gpt-5-mini is available")
        #expect(ok.requests.first?.url?.absoluteString == "https://api.openai.com/v1/models/gpt-5-mini")
        let bad = Script([.reply(status: 401, lines: [])])
        await #expect(throws: OpenAIError.unauthorized) { try await bad.client().probe() }
    }
}

struct PartialJSONTests {
    @Test func completeElementsOfAPartialReplyAreRead() {
        let text = #"{"course": {"code": "MA-UY 1124", "title": "Calc {II}"}, "gradeComponents": [], "obligations": [{"title": "HW 1", "dateAsWritten": "Wed 9/9", "dueDate": "2026-09-09", "platform": "webassign", "component": null, "confidence": "high"}, {"title": "Quiz \"1\"", "dateAsWritten": "Thu 9/17", "dueDate": "2026-09-17", "platform": "not_stated", "component": "Quizzes", "confidence": "high"}, {"title": "Midterm 1", "dateAsWri"#
        let snapshot = PartialJSON.snapshot(text)
        #expect(snapshot.values["course"] == #"{"code": "MA-UY 1124", "title": "Calc {II}"}"#)
        #expect(snapshot.arrays["gradeComponents"] == [] && snapshot.arrays["obligations"]?.count == 2)
        let rows = ExtractionJSON.provisional(text, call: 3)
        #expect(rows.map(\.title) == ["HW 1", "Quiz \"1\""] && rows[1].dateAsWritten == "Thu 9/17" && rows[0].id == "3-0")
        let salvaged = ExtractionJSON.salvage(text)
        #expect(salvaged?.course?.code == "MA-UY 1124" && salvaged?.obligations.map(\.title) == ["HW 1", "Quiz \"1\""])
        #expect(salvaged?.obligations[0].component == nil && salvaged?.obligations[1].component == "Quizzes")
    }

    @Test func aWholeReplyDecodesWithNullsAsAbsent() throws {
        let text = #"{"course": null, "gradeComponents": [{"name": "Homework", "weightPercent": 15, "count": null, "cadence": "weekly", "dropLowest": 2, "platform": "webassign"}], "obligations": [], "policies": [{"kind": "late_work", "text": "No late work."}], "noClassDates": [{"dateAsWritten": "Oct 12", "startDate": "2026-10-12", "endDate": null}]}"#
        let extraction = try ExtractionJSON.decode(text)
        #expect(extraction.course == nil && extraction.gradeComponents[0].weightPercent == 15 && extraction.gradeComponents[0].count == nil && extraction.gradeComponents[0].dropLowest == 2)
        #expect(extraction.policies[0].kind == "late_work" && extraction.noClassDates[0].endDate == nil)
        #expect(throws: OpenAIError.self) { try ExtractionJSON.decode("[1, 2]") }
        #expect(ExtractionJSON.salvage("{\"obligations\": [{\"title\": ") == nil)
    }

    @Test func thePlanDecodes() throws {
        let draft = try PlanJSON.decode(#"{"blocks": [{"start": "09:00", "end": "09:50", "title": "Quiz 3", "reason": "Due tonight.", "kind": "work"}]}"#)
        #expect(draft.blocks.count == 1 && draft.blocks[0].kind == "work")
    }

    @Test func theSchemasAreStrict() throws {
        func check(_ schema: [String: Any]) {
            if schema["type"] as? String == "object" || (schema["type"] as? [String])?.contains("object") == true {
                #expect(schema["additionalProperties"] as? Bool == false)
                let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
                #expect(Set(schema["required"] as? [String] ?? []) == Set(properties.keys))
                properties.values.forEach(check)
            }
            if let items = schema["items"] as? [String: Any] { check(items) }
        }
        for text in [OpenAISchemas.extraction, OpenAISchemas.plan] {
            let schema = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            check(schema)
        }
        let properties = try #require((try JSONSerialization.jsonObject(with: Data(OpenAISchemas.extraction.utf8)) as? [String: Any])?["properties"] as? [String: Any])
        #expect(Set(properties.keys) == ["course", "gradeComponents", "obligations", "policies", "noClassDates"])
    }
}
