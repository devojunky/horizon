import Foundation
import CryptoKit

/// The device's App Attest, as the reading service needs it: a key in the Secure Enclave, Apple's attestation of it,
/// and assertions signed with it. The app's is `DCAppAttestService`; tests script one.
public protocol AppAttesting: Sendable {
    /// False in the simulator, and wherever App Attest is not offered.
    var isSupported: Bool { get }
    func generateKey() async throws -> String
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data
}

/// App Attest's failures, in the classes that decide what happens next.
public enum AppAttestFailure: Error, Sendable, Equatable {
    /// Not offered here (the simulator, an older device).
    case unsupported
    /// The key is gone or unusable: the app was reinstalled or the device restored, and the Keychain kept its id.
    case invalidKey
    /// Apple's attestation server could not be reached; trying later can work.
    case serverUnavailable
    case other(String)
}

/// Where the id of the device's attested key is kept between launches (the app's Keychain).
public protocol AttestedKeyStore: Sendable {
    func load() -> String?
    func save(_ keyId: String?)
}

/// Horizon's reading service (Server/, DECISIONS 2026-10-23 · The tester proxy): Claude for someone with no key of
/// their own. The device proves itself with App Attest instead of an account. Its key is attested once (a challenge from
/// `/v1/challenge`, Apple's attestation of the key over it, sent to `/v1/attest`), and every request then carries an
/// assertion signed over the request's own bytes, with a counter that only goes up.
///
/// Requests go out one at a time, from the assertion until the service has answered with a status: the service accepts a
/// counter only above the last it saw, so two requests signed together and arriving the other way round would turn the
/// second away. A read and a plan share the device's key, and so this one queue.
public actor ReadingService: ClaudeRequestSigner {
    public nonisolated let serviceURL: URL
    private let attester: any AppAttesting
    private let keys: any AttestedKeyStore
    private let log: @Sendable (String) -> Void
    private var keyId: String?
    private var loaded = false
    private var sending = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    public init(serviceURL: URL, attester: any AppAttesting, keys: any AttestedKeyStore, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.serviceURL = serviceURL; self.attester = attester; self.keys = keys; self.log = log
    }

    public nonisolated var isSupported: Bool { attester.isSupported }

    public func send(_ request: URLRequest, through transport: ClaudeTransport) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, any Error>) {
        await queue()
        defer { leave() }
        var signed = request
        for (field, value) in try await proof(for: request.httpBody ?? Data(), transport: transport) { signed.setValue(value, forHTTPHeaderField: field) }
        return try await transport.send(signed)
    }

    public func renew() {
        keyId = nil
        loaded = true
        keys.save(nil)
    }

    // MARK: One at a time

    private func queue() async {
        guard sending else { sending = true; return }
        await withCheckedContinuation { waiting.append($0) }   // resumed holding the turn
    }

    private func leave() {
        if waiting.isEmpty { sending = false } else { waiting.removeFirst().resume() }
    }

    // MARK: The proof

    /// The headers that prove a request is this device's: its key's id, and an assertion over the body. A key the
    /// Secure Enclave no longer has (a reinstall kept the Keychain's id) is replaced once.
    private func proof(for body: Data, transport: ClaudeTransport) async throws -> [String: String] {
        let hash = Data(SHA256.hash(data: body))
        var replaced = false
        while true {
            let key = try await attestedKey(transport: transport)
            do {
                let assertion = try await attester.generateAssertion(key, clientDataHash: hash)
                return ["x-horizon-key-id": key, "x-horizon-assertion": assertion.base64EncodedString()]
            } catch AppAttestFailure.invalidKey where !replaced {
                replaced = true
                log("reading service: this device's key is gone (a reinstall or a restore); attesting a new one")
                renew()
            } catch {
                throw Self.classed(error)
            }
        }
    }

    /// The device's attested key, attesting one first when there is none.
    private func attestedKey(transport: ClaudeTransport) async throws -> String {
        if !loaded { keyId = keys.load(); loaded = true }
        if let keyId { return keyId }
        guard attester.isSupported else { throw ClaudeError.deviceRefused("App Attest is not available on this device") }
        do {
            let key = try await attester.generateKey()
            let challenge = try await fetchChallenge(transport: transport)
            let attestation = try await attester.attestKey(key, clientDataHash: Data(SHA256.hash(data: challenge.bytes)))
            let (status, reply) = try await exchange("attest", ["keyId": key, "attestation": attestation.base64EncodedString(), "challenge": challenge.text], transport: transport)
            // 409: the service already knows this key, from an attestation whose answer never arrived.
            guard (200..<300).contains(status.statusCode) || status.statusCode == 409 else { throw Self.refusal(status, reply) }
            keyId = key
            keys.save(key)
            log("reading service: attested a new key with \(serviceURL.host() ?? "the service")")
            return key
        } catch {
            throw Self.classed(error)
        }
    }

    private func fetchChallenge(transport: ClaudeTransport) async throws -> (text: String, bytes: Data) {
        let (status, reply) = try await exchange("challenge", [:], transport: transport)
        guard (200..<300).contains(status.statusCode) else { throw Self.refusal(status, reply) }
        guard let text = (try? JSONSerialization.jsonObject(with: reply) as? [String: Any])?["challenge"] as? String, let bytes = Self.base64URL(text) else {
            throw ClaudeError.malformed("the reading service's challenge could not be read")
        }
        return (text, bytes)
    }

    /// One small JSON exchange with the service (the challenge, the attestation), its whole reply collected.
    private func exchange(_ path: String, _ fields: [String: String], transport: ClaudeTransport) async throws -> (HTTPURLResponse, Data) {
        var request = URLRequest(url: serviceURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: fields)
        let (http, lines) = try await transport.send(request)
        var text = ""
        for try await line in lines { text += line + "\n"; if text.count > 65_536 { break } }
        return (http, Data(text.utf8))
    }

    /// A refusal from the challenge or attestation endpoint, classed as the Messages API's are.
    private static func refusal(_ http: HTTPURLResponse, _ reply: Data) -> ClaudeError {
        let error = (try? JSONSerialization.jsonObject(with: reply) as? [String: Any])?["error"] as? [String: Any]
        if http.statusCode == 429 { return .rateLimited(retryAfter: http.value(forHTTPHeaderField: "retry-after").flatMap(Double.init)) }
        return ClaudeClient.apiError(status: http.statusCode, type: error?["type"] as? String ?? "", message: error?["message"] as? String ?? "", model: ClaudeModelChoice.sonnet.rawValue)
    }

    /// Any failure on the way, as the client's classes: App Attest's in the user's terms, the network's as the client
    /// maps them.
    private static func classed(_ error: any Error) -> any Error {
        switch error {
        case let failure as AppAttestFailure:
            switch failure {
            case .unsupported: return ClaudeError.deviceRefused("App Attest is not available on this device")
            case .invalidKey: return ClaudeError.deviceRefused("this device's key could not be used")
            case .serverUnavailable: return ClaudeError.network("Apple's attestation service could not be reached")
            case .other(let why): return ClaudeError.deviceRefused(why)
            }
        default: return ClaudeClient.mapTransport(error)
        }
    }

    /// The challenge's bytes: URL-safe base64, unpadded, as the service writes it.
    static func base64URL(_ text: String) -> Data? {
        var normal = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        normal += String(repeating: "=", count: (4 - normal.count % 4) % 4)
        return Data(base64Encoded: normal)
    }
}
