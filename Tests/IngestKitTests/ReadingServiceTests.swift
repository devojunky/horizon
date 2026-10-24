import Testing
import Foundation
import CryptoKit
@testable import IngestKit

/// Horizon's reading service from the device's side, against scripted transports: the attestation a first read makes,
/// the proof every request carries, and what each of the service's answers leads to.
struct ReadingServiceTests {
    typealias Script = ClaudeClientTests.Script

    /// App Attest as the tests have it: keys numbered as they are made, and every hash it was asked to sign.
    final class Attester: AppAttesting, @unchecked Sendable {
        private let lock = NSLock()
        var supported = true
        private(set) var made = 0
        private(set) var attested: [(key: String, hash: Data)] = []
        private(set) var asserted: [(key: String, hash: Data)] = []
        var lostKeys: Set<String> = []
        var events: [String] = []
        var isSupported: Bool { lock.withLock { supported } }
        func generateKey() async throws -> String { lock.withLock { made += 1; return "key-\(made)" } }
        func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
            lock.withLock { attested.append((keyId, clientDataHash)) }
            return Data("attestation of \(keyId)".utf8)
        }
        func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
            try lock.withLock {
                if lostKeys.contains(keyId) { throw AppAttestFailure.invalidKey }
                asserted.append((keyId, clientDataHash))
                events.append("assert \(asserted.count)")
                return Data("assertion \(asserted.count) by \(keyId)".utf8)
            }
        }
        func note(_ event: String) { lock.withLock { events.append(event) } }
    }

    final class Keys: AttestedKeyStore, @unchecked Sendable {
        private let lock = NSLock()
        private var kept: String?
        init(_ kept: String? = nil) { self.kept = kept }
        func load() -> String? { lock.withLock { kept } }
        func save(_ keyId: String?) { lock.withLock { kept = keyId } }
    }

    static let service = URL(string: "https://reading.example/v1")!
    /// A challenge as the service writes it: 56 bytes, URL-safe base64 without padding.
    static let challengeBytes = Data((0..<56).map { UInt8(($0 * 37 + 11) % 256) })
    static var challengeText: String {
        challengeBytes.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static let challenge = ClaudeClientTests.Step.reply(status: 200, lines: [#"{"challenge":"\#(challengeText)"}"#])
    static let attested = ClaudeClientTests.Step.reply(status: 200, lines: [#"{"ok":true}"#])
    static func refused(_ status: Int, _ type: String, _ message: String, headers: [String: String] = [:]) -> ClaudeClientTests.Step {
        .reply(status: status, headers: headers, lines: [#"{"type":"error","error":{"type":"\#(type)","message":"\#(message)"}}"#])
    }

    static func client(_ script: Script, _ attester: Attester, _ keys: Keys) -> (ClaudeClient, ReadingService) {
        let service = ReadingService(serviceURL: Self.service, attester: attester, keys: keys)
        return (ClaudeClient(configuration: ClaudeConfiguration(service: service), transport: script.transport, sleep: { _ in }), service)
    }

    static var noThinking: ClaudeClient.Request { var r = ClaudeClientTests.request; r.thinking = .off; return r }

    @Test func aFirstReadAttestsTheDeviceThenSignsTheRequestsOwnBytes() async throws {
        let script = Script([Self.challenge, Self.attested, .reply(status: 200, lines: ClaudeClientTests.whole("{}"))])
        let attester = Attester(), keys = Keys()
        let (client, _) = Self.client(script, attester, keys)
        _ = try await client.stream(Self.noThinking)

        #expect(script.sent.map { $0.url?.path } == ["/v1/challenge", "/v1/attest", "/v1/messages"])
        // The attestation is over the challenge's bytes, and sent with the challenge as it came.
        #expect(attester.attested.map(\.key) == ["key-1"] && attester.attested.first?.hash == Data(SHA256.hash(data: Self.challengeBytes)))
        let attest = try #require(try JSONSerialization.jsonObject(with: script.sent[1].httpBody!) as? [String: String])
        #expect(attest == ["keyId": "key-1", "attestation": Data("attestation of key-1".utf8).base64EncodedString(), "challenge": Self.challengeText])
        #expect(keys.load() == "key-1")
        // The read carries the device's proof over its own bytes, and no key of anyone's.
        let read = script.sent[2]
        #expect(read.value(forHTTPHeaderField: "x-horizon-key-id") == "key-1" && read.value(forHTTPHeaderField: "x-api-key") == nil)
        #expect(read.value(forHTTPHeaderField: "x-horizon-assertion") == Data("assertion 1 by key-1".utf8).base64EncodedString())
        #expect(attester.asserted.first?.hash == Data(SHA256.hash(data: read.httpBody!)))
        // Written for the service's model: Sonnet 5.5, told not to think its own way.
        let body = try #require(try JSONSerialization.jsonObject(with: read.httpBody!) as? [String: Any])
        #expect(body["model"] as? String == "claude-sonnet-5-5" && (body["thinking"] as? [String: Any])?["type"] as? String == "between_tools")
    }

    @Test func aKeptKeyIsUsedAsItIs() async throws {
        let script = Script([.reply(status: 200, lines: ClaudeClientTests.whole("{}"))])
        let attester = Attester()
        _ = try await Self.client(script, attester, Keys("key-7")).0.stream(ClaudeClientTests.request)
        #expect(script.sent.count == 1 && script.sent[0].value(forHTTPHeaderField: "x-horizon-key-id") == "key-7" && attester.made == 0)
    }

    @Test func aKeyTheServiceDoesNotKnowIsReplacedOnceThenTheAnswerStands() async throws {
        let script = Script([Self.refused(401, "horizon_unknown_key", "not known"), Self.challenge, Self.attested, .reply(status: 200, lines: ClaudeClientTests.whole("{}"))])
        let attester = Attester(), keys = Keys("key-7")
        _ = try await Self.client(script, attester, keys).0.stream(ClaudeClientTests.request)
        #expect(script.sent.map { $0.url?.path } == ["/v1/messages", "/v1/challenge", "/v1/attest", "/v1/messages"])
        #expect(script.sent[3].value(forHTTPHeaderField: "x-horizon-key-id") == "key-1" && keys.load() == "key-1")

        // Refused again with the new key: that is the answer, with no third key.
        let twice = Script([Self.refused(401, "horizon_unknown_key", "not known"), Self.challenge, Self.attested, Self.refused(401, "horizon_unknown_key", "not known")])
        await #expect(throws: ClaudeError.deviceUnknown) { try await Self.client(twice, Attester(), Keys("key-7")).0.stream(ClaudeClientTests.request) }
        #expect(twice.sent.count == 4)
    }

    @Test func aKeyTheDeviceLostIsReplacedBeforeAnythingIsSent() async throws {
        let script = Script([Self.challenge, Self.attested, .reply(status: 200, lines: ClaudeClientTests.whole("{}"))])
        let attester = Attester(); attester.lostKeys = ["key-7"]   // a reinstall: the Keychain kept the id, the Secure Enclave not the key
        let keys = Keys("key-7")
        _ = try await Self.client(script, attester, keys).0.stream(ClaudeClientTests.request)
        #expect(script.sent.map { $0.url?.path } == ["/v1/challenge", "/v1/attest", "/v1/messages"] && keys.load() == "key-1")
    }

    @Test func aUsedUpAllowanceWaitsUntilItComesBack() async throws {
        let resets = "2026-10-24T00:00:00.000Z"
        let script = Script([Self.refused(403, "horizon_quota", "used up", headers: ["x-horizon-resets-at": resets])])
        let error = await #expect(throws: ClaudeError.self) { try await Self.client(script, Attester(), Keys("key-7")).0.stream(ClaudeClientTests.request) }
        #expect(error == .allowanceUsed(resetsAt: try Date(resets, strategy: .iso8601)) && script.sent.count == 1)   // no retry: waiting is the fix
        let words = Extractor.explainClaude(try #require(error))
        #expect(words.hasPrefix("this device's allowance on Horizon's reading service is used up until ") && words.hasSuffix("or can be read on this device"))
    }

    @Test func aRefusedAttestationIsTriedWithOneNewKeyAndThenSaid() async throws {
        let message = "The attestation was refused: not a development attestation."
        let script = Script([Self.challenge, Self.refused(401, "horizon_attestation", message), Self.challenge, Self.refused(401, "horizon_attestation", message)])
        await #expect(throws: ClaudeError.deviceRefused(message)) { try await Self.client(script, Attester(), Keys()).0.stream(ClaudeClientTests.request) }
        #expect(script.sent.map { $0.url?.path } == ["/v1/challenge", "/v1/attest", "/v1/challenge", "/v1/attest"])

        let simulator = Attester(); simulator.supported = false
        await #expect(throws: ClaudeError.deviceRefused("App Attest is not available on this device")) {
            try await Self.client(Script([]), simulator, Keys()).0.stream(ClaudeClientTests.request)
        }
    }

    @Test func busyAndUnavailableAreWaitedOutThenSaidInTheUsersWords() async throws {
        let script = Script([Self.refused(409, "horizon_busy", "busy"), .reply(status: 200, lines: ClaudeClientTests.whole("{}"))])
        let completion = try await Self.client(script, Attester(), Keys("key-7")).0.stream(ClaudeClientTests.request)
        #expect(completion.attempts == 2)

        let down = Script(Array(repeating: Self.refused(503, "horizon_unavailable", "down"), count: 4))
        let error = await #expect(throws: ClaudeError.self) { try await Self.client(down, Attester(), Keys("key-7")).0.stream(ClaudeClientTests.request) }
        #expect(Extractor.explainClaude(try #require(error)) == "Horizon's reading service is not available right now")
    }

    @Test func requestsAreSignedOneAtATimeSoTheirCountersArriveInOrder() async throws {
        let attester = Attester()
        let service = ReadingService(serviceURL: Self.service, attester: attester, keys: Keys("key-7"))
        let transport = ClaudeTransport { request in
            let proof = request.value(forHTTPHeaderField: "x-horizon-assertion").flatMap { Data(base64Encoded: $0) }.map { String(decoding: $0, as: UTF8.self) } ?? ""
            attester.note("sent \(proof)")
            try await Task.sleep(for: .milliseconds(80))   // the service checking the proof
            attester.note("answered \(proof)")
            let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!
            return (http, AsyncThrowingStream { continuation in ClaudeClientTests.whole("{}").forEach { continuation.yield($0) }; continuation.finish() })
        }
        let client = ClaudeClient(configuration: ClaudeConfiguration(service: service), transport: transport, sleep: { _ in })
        async let first = client.stream(ClaudeClientTests.request)
        async let second = client.stream(ClaudeClientTests.request)
        _ = try await (first, second)
        // Each assertion is made only once the request before it has its answer; without the queue the second was signed
        // while the first waited, and a service seeing them the other way round turns one away.
        #expect(attester.events == ["assert 1", "sent assertion 1 by key-7", "answered assertion 1 by key-7",
                                    "assert 2", "sent assertion 2 by key-7", "answered assertion 2 by key-7"])
    }
}
