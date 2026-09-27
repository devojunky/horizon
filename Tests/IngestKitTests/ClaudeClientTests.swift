import Testing
import Foundation
@testable import IngestKit

/// The Claude client against scripted transports: what it sends, how it reads a stream, and which failures it retries.
struct ClaudeClientTests {
    enum Step {
        case reply(status: Int, headers: [String: String] = [:], lines: [String], dropAfter: Int? = nil)
        case fail(URLError.Code)
    }

    /// A transport that plays a script, one step per request, and remembers what it was sent.
    final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private var steps: [Step]
        private(set) var requests: [URLRequest] = []
        var slept: [TimeInterval] = []
        init(_ steps: [Step]) { self.steps = steps }

        var transport: ClaudeTransport {
            ClaudeTransport { request in
                let step: Step? = self.lock.withLock { self.requests.append(request); return self.steps.isEmpty ? nil : self.steps.removeFirst() }
                guard let step else { throw URLError(.badServerResponse) }
                switch step {
                case .fail(let code): throw URLError(code)
                case .reply(let status, let headers, let lines, let dropAfter):
                    let http = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
                    let stream = AsyncThrowingStream<String, any Error> { continuation in
                        for (i, line) in lines.enumerated() {
                            if let dropAfter, i >= dropAfter { continuation.finish(throwing: URLError(.networkConnectionLost)); return }
                            continuation.yield(line)
                        }
                        continuation.finish()
                    }
                    return (http, stream)
                }
            }
        }

        func client(model: ClaudeModelChoice = .sonnet5, attempts: Int = 4) -> ClaudeClient {
            var policy = ClaudeClient.Policy(); policy.attempts = attempts
            return ClaudeClient(configuration: ClaudeConfiguration(apiKey: "sk-ant-test", model: model), transport: transport, policy: policy,
                                sleep: { s in self.lock.withLock { self.slept.append(s) } })
        }
        var sent: [URLRequest] { lock.withLock { requests } }
        var body: [String: Any] { (try? JSONSerialization.jsonObject(with: sent.first!.httpBody!)) as? [String: Any] ?? [:] }
    }

    static let request = ClaudeClient.Request(system: "sys", user: "read this", schema: ClaudeSchemas.extraction, maxOutputTokens: 500)

    /// One SSE event line. The stream a real reply makes: message_start, deltas, message_delta, message_stop.
    static func event(_ type: String, _ fields: String = "") -> String { "data: {\"type\": \"\(type)\"\(fields.isEmpty ? "" : ", " + fields)}" }
    static func delta(_ text: String) -> String { event("content_block_delta", "\"index\": 0, \"delta\": {\"type\": \"text_delta\", \"text\": \(ClaudeSchemas.quote(text))}") }
    static func whole(_ text: String, out: Int = 40) -> [String] {
        [event("message_start", "\"message\": {\"usage\": {\"input_tokens\": 300, \"cache_read_input_tokens\": 100}}"), "", delta(text), "",
         event("message_delta", "\"delta\": {\"stop_reason\": \"end_turn\"}, \"usage\": {\"output_tokens\": \(out)}"), "", event("message_stop")]
    }

    @Test func streamsTheTextAndReadsTheUsage() async throws {
        let json = #"{"course": {"code": "MA 1"}, "gradeComponents": [], "obligations": [], "policies": [], "noClassDates": []}"#
        let cut = json.index(json.startIndex, offsetBy: 20)
        let script = Script([.reply(status: 200, lines: [Self.event("message_start", "\"message\": {\"usage\": {\"input_tokens\": 300}}"), Self.delta(String(json[..<cut])), Self.delta(String(json[cut...])),
                                                          Self.event("message_delta", "\"delta\": {\"stop_reason\": \"end_turn\"}, \"usage\": {\"output_tokens\": 60}"), Self.event("message_stop")])])
        let seen = Seen()
        let completion = try await script.client().stream(Self.request) { text in seen.append(text) }
        #expect(completion.text == json && completion.stopReason == "end_turn" && completion.inputTokens == 300 && completion.outputTokens == 60 && completion.attempts == 1)
        #expect(seen.value.count == 2 && seen.value.last == json)   // the whole text so far, every time
    }

    @Test func sendsAStreamingStructuredRequestInTheSchemasOrder() async throws {
        let script = Script([.reply(status: 200, lines: Self.whole("{}"))])
        _ = try await script.client().stream(ClaudeClient.Request(system: "sys", user: "read", images: [Data([1, 2, 3])], schema: ClaudeSchemas.extraction, maxOutputTokens: 500))
        let request = script.sent.first!
        #expect(request.url?.path == "/v1/messages" && request.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test" && request.value(forHTTPHeaderField: "anthropic-version") == ClaudeClient.apiVersion)
        let body = script.body
        #expect(body["model"] as? String == "claude-sonnet-5" && body["stream"] as? Bool == true && body["max_tokens"] as? Int == 500 && body["system"] as? String == "sys")
        let content = ((body["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]]) ?? []
        #expect(content.map { $0["type"] as? String } == ["image", "text"])   // the pictures, then the words
        #expect(((content.first?["source"] as? [String: Any])?["media_type"] as? String) == "image/jpeg")
        let output = body["output_config"] as? [String: Any]
        #expect((output?["format"] as? [String: Any])?["type"] as? String == "json_schema" && output?["effort"] as? String == "medium")
        // The order in the body is the order written: course's keys as the model should write them.
        let text = String(decoding: request.httpBody!, as: UTF8.self)
        let positions = ["\"code\"", "\"title\"", "\"instructor\"", "\"term\"", "\"termStart\"", "\"termEnd\"", "\"room\"", "\"meetings\""].map { text.range(of: $0)!.lowerBound }
        #expect(positions == positions.sorted())
        #expect(text.range(of: "\"course\"")!.lowerBound < text.range(of: "\"gradeComponents\"")!.lowerBound && text.range(of: "\"gradeComponents\"")!.lowerBound < text.range(of: "\"obligations\"")!.lowerBound)
    }

    @Test func haikuIsSentNoEffort() async throws {
        let script = Script([.reply(status: 200, lines: Self.whole("{}"))])
        _ = try await script.client(model: .haiku45).stream(Self.request)
        #expect((script.body["output_config"] as? [String: Any])?["effort"] == nil && script.body["model"] as? String == "claude-haiku-4-5")
    }

    @Test func aDroppedStreamIsRetriedFromTheStart() async throws {
        let script = Script([.reply(status: 200, lines: Self.whole("{\"a\": 1}"), dropAfter: 3), .reply(status: 200, lines: Self.whole("{\"a\": 2}"))])   // cut after the first delta
        let seen = Seen()
        let completion = try await script.client().stream(Self.request) { text in seen.append(text) }
        #expect(completion.text == "{\"a\": 2}" && completion.attempts == 2 && script.slept == [0.5])
        #expect(seen.value.first == "{\"a\": 1}" && seen.value.last == "{\"a\": 2}")   // the retry starts over; the caller replaces, never appends
    }

    @Test func aStreamThatEndsWithoutAStopIsInterruptedAndRetried() async throws {
        let script = Script([.reply(status: 200, lines: [Self.delta("{\"a\":")]), .reply(status: 200, lines: Self.whole("{}"))])
        let completion = try await script.client().stream(Self.request)
        #expect(completion.attempts == 2)
    }

    @Test func rateLimitsWaitForRetryAfterAndOverloadsBackOff() async throws {
        let limited = Script([.reply(status: 429, headers: ["retry-after": "3"], lines: [#"{"type": "error", "error": {"type": "rate_limit_error", "message": "slow down"}}"#]),
                              .reply(status: 529, lines: [#"{"type": "error", "error": {"type": "overloaded_error", "message": "busy"}}"#]),
                              .reply(status: 500, lines: [#"{"type": "error", "error": {"type": "api_error", "message": "oops"}}"#]),
                              .reply(status: 200, lines: Self.whole("{}"))])
        let completion = try await limited.client().stream(Self.request)
        #expect(completion.attempts == 4 && limited.slept == [3, 1.0, 2.0])   // the server's wait, then doubling
    }

    @Test func aBadKeyOrModelOrRequestIsNotRetried() async throws {
        let bad = Script([.reply(status: 401, lines: [#"{"type": "error", "error": {"type": "authentication_error", "message": "invalid x-api-key"}}"#])])
        await #expect(throws: ClaudeError.unauthorized) { try await bad.client().stream(Self.request) }
        #expect(bad.sent.count == 1)
        let missing = Script([.reply(status: 404, lines: [#"{"type": "error", "error": {"type": "not_found_error", "message": "model: claude-x"}}"#])])
        await #expect(throws: ClaudeError.modelNotFound("claude-sonnet-5")) { try await missing.client().stream(Self.request) }
        let malformed = Script([.reply(status: 400, lines: [#"{"type": "error", "error": {"type": "invalid_request_error", "message": "schema: bad"}}"#])])
        await #expect(throws: ClaudeError.badRequest("schema: bad")) { try await malformed.client().stream(Self.request) }
    }

    @Test func aRequestTooLargeIsItsOwnError() async throws {
        let big = Script([.reply(status: 400, lines: [#"{"type": "error", "error": {"type": "invalid_request_error", "message": "prompt is too long: 210000 tokens > 200000 maximum"}}"#])])
        await #expect(throws: ClaudeError.payloadTooLarge) { try await big.client().stream(Self.request) }
        let http413 = Script([.reply(status: 413, lines: ["{}"])])
        await #expect(throws: ClaudeError.payloadTooLarge) { try await http413.client().stream(Self.request) }
    }

    @Test func persistentFailuresGiveUpAfterFourAttempts() async throws {
        let down = Script([.fail(.cannotConnectToHost), .fail(.cannotConnectToHost), .fail(.cannotConnectToHost), .fail(.cannotConnectToHost)])
        await #expect(throws: ClaudeError.exhausted(attempts: 4, last: ClaudeError.network("cannot connect").localizedDescription)) { try await down.client().stream(Self.request) }
        #expect(down.slept == [0.5, 1.0, 2.0])
    }

    @Test func cancellationIsNotRetried() async throws {
        let script = Script([.fail(.cancelled), .reply(status: 200, lines: Self.whole("{}"))])
        await #expect(throws: CancellationError.self) { try await script.client().stream(Self.request) }
        #expect(script.sent.count == 1)
    }

    @Test func aMidStreamErrorEventIsReportedAndRetried() async throws {
        let script = Script([.reply(status: 200, lines: [Self.delta("{"), Self.event("error", #""error": {"type": "overloaded_error", "message": "Overloaded"}"#)]), .reply(status: 200, lines: Self.whole("{}"))])
        let completion = try await script.client().stream(Self.request)
        #expect(completion.attempts == 2)
    }

    @Test func theProbeAsksForOneWord() async throws {
        let script = Script([.reply(status: 200, lines: Self.whole(#"{"answer": "OK"}"#))])
        #expect(try await script.client().probe() == "Sonnet 5 answered.")
        #expect(script.body["max_tokens"] as? Int == 16)
        let bad = Script([.reply(status: 401, lines: [#"{"type": "error", "error": {"type": "authentication_error", "message": "no"}}"#])])
        await #expect(throws: ClaudeError.unauthorized) { try await bad.client().probe() }
    }

    // MARK: The JSON the model writes

    @Test func completeElementsOfAPartialReplyAreRead() {
        let text = #"{"course": {"code": "MA-UY 1124", "meetings": []}, "gradeComponents": [{"name": "Homework", "cadence": "weekly", "platform": "webassign"}], "obligations": [{"title": "HW 1", "platform": "webassign", "dateAsWritten": "Wed 9/9", "dueDate": "2026-09-09", "confidence": "high"}, {"title": "HW 2", "platform": "web"#
        let rows = ExtractionJSON.provisional(text, call: 3)
        #expect(rows.map(\.title) == ["HW 1"] && rows.first?.id == "3-0" && rows.first?.dateAsWritten == "Wed 9/9")
        let salvaged = ExtractionJSON.salvage(text)
        #expect(salvaged?.course?.code == "MA-UY 1124" && salvaged?.gradeComponents.map(\.name) == ["Homework"] && salvaged?.obligations.map(\.title) == ["HW 1"])
    }

    @Test func aPictureReplyCarriesItsTranscriptAndNestedFacts() throws {
        let text = #"{"transcript": "Gradescope\nHomework 1  Sep 16 at 11:59PM", "facts": {"gradeComponents": [], "obligations": [{"title": "Homework 1", "platform": "gradescope", "dateAsWritten": "Sep 16 at 11:59PM", "dueDate": "2026-09-16", "confidence": "high"}], "policies": [], "noClassDates": []}}"#
        let read = try PageReadingJSON.decode(text)
        #expect(read.transcript.hasPrefix("Gradescope") && read.facts.obligations.map(\.title) == ["Homework 1"])
        // Cut inside the list, after the first item closed: the rows so far, and what a cut reply keeps.
        let partial = String(text[..<text.range(of: "], \"policies\"")!.lowerBound]) + #", {"title": "Homework 2", "plat"#
        #expect(PageReadingJSON.provisional(partial, call: 1).map(\.title) == ["Homework 1"])
        #expect(PageReadingJSON.salvage(partial)?.facts.obligations.count == 1)
    }

    @Test func aWholeReplyDecodesWithMissingKeysAsAbsent() throws {
        let text = #"{"course": {"code": "MA-UY 1124", "term": "Fall 2026", "meetings": [{"weekday": "mon"}]}, "gradeComponents": [{"name": "Quizzes", "weightPercent": 12, "cadence": "biweekly", "platform": "not_stated"}], "obligations": [{"title": "Quiz 1", "platform": "not_stated", "dateAsWritten": "Thu 9/17", "confidence": "medium"}], "policies": [{"kind": "late_work", "text": "No late work."}], "noClassDates": [{"dateAsWritten": "Oct 12", "startDate": "2026-10-12"}]}"#
        let e = try ExtractionJSON.decode(text)
        #expect(e.course?.title == nil && e.course?.meetings.first?.start == nil && e.gradeComponents.first?.count == nil && e.obligations.first?.dueDate == nil && e.noClassDates.first?.endDate == nil)
        #expect(e.obligations.first?.title == "Quiz 1" && e.policies.first?.kind == "late_work")
    }

    @Test func thePlanDecodes() throws {
        let text = #"{"blocks": [{"start": "09:00", "end": "09:50", "title": "Quiz 3", "reason": "Go over the practice set.", "kind": "study"}, {"start": "10:00", "end": "10:4"#
        #expect(PlanJSON.provisional(text).blocks.map(\.title) == ["Quiz 3"] && PlanJSON.provisional(text).blocks.first?.kind == "study")
        #expect(PlanJSON.provisional("{\"blo").blocks.isEmpty)
        #expect(try PlanJSON.decode(#"{"blocks": []}"#).blocks.isEmpty)
        let calendar = try CalendarJSON.decode(#"{"events": [{"title": "Calc lecture", "use": "fixed", "course": "any"}, {"title": "Math study session", "use": "coursework", "course": "Calculus II"}]}"#)
        #expect(calendar.events.map(\.use) == ["fixed", "coursework"] && calendar.events.last?.title == "Math study session" && calendar.events.last?.course == "Calculus II")
    }

    @Test func theSchemasAreValidJSONInTheOrderWritten() throws {
        for schema in [ClaudeSchemas.extraction, ClaudeSchemas.pageReading, ClaudeSchemas.plan] {
            let object = try JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any]
            #expect(object?["additionalProperties"] as? Bool == false && object?["type"] as? String == "object")
        }
        let s = ClaudeSchemas.extraction
        #expect(s.range(of: "\"course\"")!.lowerBound < s.range(of: "\"gradeComponents\"")!.lowerBound)
        #expect(s.range(of: "\"transcript\"") == nil && ClaudeSchemas.pageReading.range(of: "\"transcript\"")!.lowerBound < ClaudeSchemas.pageReading.range(of: "\"facts\"")!.lowerBound)
        let extraction = try JSONSerialization.jsonObject(with: Data(s.utf8)) as! [String: Any]
        #expect((extraction["required"] as? [String]) == ["outline", "gradeComponents", "obligations", "policies", "noClassDates"])   // the course is optional, a chunk may not name it
        #expect(s.range(of: "\"outline\"")!.lowerBound < s.range(of: "\"course\"")!.lowerBound)   // the outline is written before anything else
        let calendar = ClaudeSchemas.calendar
        #expect(calendar.range(of: "\"title\"")!.lowerBound < calendar.range(of: "\"use\"")!.lowerBound)   // the event said back before its label
        #expect((try JSONSerialization.jsonObject(with: Data(calendar.utf8)) as? [String: Any])?["additionalProperties"] as? Bool == false)
    }
}

final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var value: [String] { lock.withLock { stored } }
    func append(_ s: String) { lock.withLock { stored.append(s) } }
}

/// Where a streaming reply stands, read off the JSON so far: the outline first, then each stage and its count.
struct ReadProgressTests {
    static let outline = #"{"outline": {"obligationTitles": ["HW 1", "HW 2", "Quiz 1"], "gradeRows": 2, "policies": 1, "breaks": 1}"#

    @Test func theOutlineComesFirstAndSetsTheTotals() {
        let sizing = ExtractionJSON.progress(#"{"outline": {"obligationTitles": ["HW 1", "HW"#)
        #expect(sizing.stage == .sizing && sizing.outline == nil && sizing.done == 1)   // the names counted as they arrive
        let measured = ExtractionJSON.progress(Self.outline + #", "course": {"code": "MA"#)
        #expect(measured.stage == .course && measured.outline?.titles == ["HW 1", "HW 2", "Quiz 1"] && measured.outline?.gradeRows == 2)
        #expect(ExtractionJSON.progress("").stage == .sizing && ExtractionJSON.progress("{").stage == .sizing)
    }

    @Test func eachStageCountsItsFinishedItemsAndNamesTheNext() {
        let rows = Self.outline + #", "course": {"meetings": []}, "gradeComponents": [{"name": "HW", "cadence": "weekly", "platform": "lms"}, {"na"#
        let grading = ExtractionJSON.progress(rows)
        #expect(grading.stage == .grading && grading.done == 1 && grading.total == 2)
        let items = Self.outline + #", "course": {"meetings": []}, "gradeComponents": [], "obligations": [{"title": "HW 1", "platform": "lms", "dateAsWritten": "9/9", "confidence": "high"}, {"title": "HW"#
        let obligations = ExtractionJSON.progress(items)
        #expect(obligations.stage == .obligations && obligations.done == 1 && obligations.total == 3 && obligations.current == "HW 2")
        let closed = Self.outline + #", "course": {"meetings": []}, "gradeComponents": [], "obligations": [], "policies": [], "noClassDates": [{"dateAsWritten": "Oct 12"}]}"#
        let done = ExtractionJSON.progress(closed)
        #expect(done.stage == .breaks && done.done == 1 && done.total == 1)
    }

    @Test func theOutlinesNamesStandInForItemsNotYetWritten() {
        let text = Self.outline + #", "course": {"meetings": []}, "gradeComponents": [], "obligations": [{"title": "HW 1", "platform": "lms", "dateAsWritten": "9/9", "confidence": "high"}, {"title": "HW"#
        let rows = ExtractionJSON.provisional(text, call: 2)
        #expect(rows.map(\.title) == ["HW 1", "HW 2", "Quiz 1"] && rows.map(\.id) == ["2-0", "2-1", "2-2"])   // the same ids, so a row carries over
        #expect(rows[0].dateAsWritten == "9/9" && rows[1].dateAsWritten == nil)
    }

    @Test func aPictureIsTranscribedBeforeItsStages() {
        #expect(PageReadingJSON.progress(#"{"transcript": "Gradescope\nHomework"#).stage == .transcribing)
        let facts = #"{"transcript": "…", "facts": "# + Self.outline + #", "course": {"meetings": []}, "gradeComponents": [], "obligations": [{"ti"#
        let p = PageReadingJSON.progress(facts)
        #expect(p.stage == .obligations && p.done == 0 && p.total == 3 && p.current == "HW 1")
    }
}
