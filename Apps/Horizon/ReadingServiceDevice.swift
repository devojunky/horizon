import Foundation
import HorizonCore
import IngestKit
#if canImport(DeviceCheck)
import DeviceCheck
#endif

/// The device's side of Horizon's reading service (IngestKit's `ReadingService`; Server/; DECISIONS 2026-10-23 · The
/// reading service in the app, 2026-10-28 · The reading service on the Mac): App Attest through `DCAppAttestService`, the
/// attested key's id in the Keychain, and where the service is for this build (`HorizonReadingService` in Info.plist,
/// from Base.xcconfig: the development service for Debug builds, production for Release). An iPhone's evidence names
/// the build's App Attest environment; a Mac's names production whatever the build (macOS has no development
/// environment, and the Mac carries no entitlement for one), which the development service takes too.
extension AppModel {
    /// The service this device can read through, or nil: not configured, or not offered here (the simulator, where App
    /// Attest is not). A scratch run keeps its key in memory, since the Keychain is the user's: on a Mac, whose app is
    /// only ever tested on a scratch copy, that is how `--probe-reading-service` reaches the service.
    /// `--show-reading-service` (DEBUG) offers one whose every attestation fails, to look at Settings where App Attest is not.
    static let readingService: ReadingService? = {
        #if DEBUG
        if scratchStore != nil { return service { _ in MemoryAttestedKey() } }
        #endif
        return service { KeychainAttestedKey(host: $0) }
    }()

    private static func service(keys: (_ host: String) -> any AttestedKeyStore) -> ReadingService? {
        guard let text = Bundle.main.object(forInfoDictionaryKey: "HorizonReadingService") as? String,
              let url = URL(string: text), let host = url.host(), url.scheme == "https" else { return nil }
        let log: @Sendable (String) -> Void = { message in Task { @MainActor in AppModel.log(message) } }
        #if DEBUG
        if CommandLine.arguments.contains("--show-reading-service") {
            return ReadingService(serviceURL: url, attester: ShownOnlyAttester(), keys: keys(host), log: log)
        }
        #endif
        guard DeviceAttester().isSupported else { return nil }
        return ReadingService(serviceURL: url, attester: DeviceAttester(), keys: keys(host), log: log)
    }
}

/// The id of the device's attested key, per service: a key attested with the development service is unknown to
/// production's. In the Keychain, which keeps it across a reinstall that loses the key itself (`AppAttestFailure.invalidKey`
/// then makes a new one).
struct KeychainAttestedKey: AttestedKeyStore {
    let host: String
    private var account: String { "readingServiceKey:\(host)" }
    func load() -> String? { Keychain.read(account) }
    func save(_ keyId: String?) { Keychain.write(keyId ?? "", account: account) }
}

#if DEBUG
/// A scratch run's key id, for as long as the run lasts: each run attests a key of its own.
final class MemoryAttestedKey: AttestedKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keyId: String?
    func load() -> String? { lock.withLock { keyId } }
    func save(_ keyId: String?) { lock.withLock { self.keyId = keyId } }
}
#endif

/// App Attest itself, its failures in the classes the service acts on.
struct DeviceAttester: AppAttesting {
    var isSupported: Bool { DCAppAttestService.shared.isSupported }

    func generateKey() async throws -> String {
        try await classed { try await DCAppAttestService.shared.generateKey() }
    }

    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        #if os(macOS)
        // A key made a moment ago that cannot be used is not a key gone: a Mac lets App Attest's keys sign only when it
        // starts up with Full Security (the Secure Enclave refuses below it; seen on a Mac set to Reduced Security).
        do { return try await classed { try await DCAppAttestService.shared.attestKey(keyId, clientDataHash: clientDataHash) } }
        catch AppAttestFailure.invalidKey { throw AppAttestFailure.other("this Mac does not start up with Full Security") }
        #else
        try await classed { try await DCAppAttestService.shared.attestKey(keyId, clientDataHash: clientDataHash) }
        #endif
    }

    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
        try await classed { try await DCAppAttestService.shared.generateAssertion(keyId, clientDataHash: clientDataHash) }
    }

    private func classed<T>(_ work: () async throws -> T) async throws -> T {
        do { return try await work() }
        catch let error as DCError {
            switch error.code {
            case .featureUnsupported: throw AppAttestFailure.unsupported
            case .invalidKey: throw AppAttestFailure.invalidKey
            case .serverUnavailable: throw AppAttestFailure.serverUnavailable
            default: throw AppAttestFailure.other(error.localizedDescription)
            }
        }
    }

    #if DEBUG
    /// `--probe-app-attest`: App Attest here with no service, a throwaway key attested over random bytes: whether it is
    /// offered, and the environment its evidence names (the AAGUID in the attestation's authenticator data), which the
    /// service checks against its own. Nothing is kept or sent anywhere but Apple.
    static func probe() async -> String {
        let attester = DeviceAttester()
        guard attester.isSupported else { return "not supported" }
        do {
            let key = try await attester.generateKey()
            let attestation = try await attester.attestKey(key, clientDataHash: Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
            return "supported, \(attestation.count) bytes of evidence for the \(environment(of: attestation)) environment"
        } catch { return "supported, but \(error)" }
    }

    /// "development" or "production" from the AAGUID ("appattestdevelop", or "appattest" and seven zeros) at bytes 37–52
    /// of the authenticator data, the byte string under the CBOR key "authData".
    private static func environment(of attestation: Data) -> String {
        let bytes = [UInt8](attestation), key = [0x68] + Array("authData".utf8)
        guard bytes.count > key.count + 3, let start = (0...(bytes.count - key.count - 3)).first(where: { Array(bytes[$0..<($0 + key.count)]) == key }) else { return "unreadable" }
        var at = start + key.count
        let length: Int
        switch bytes[at] {
        case 0x58: length = Int(bytes[at + 1]); at += 2
        case 0x59: length = Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]); at += 3
        default: return "unreadable"
        }
        guard length >= 53, at + 53 <= bytes.count else { return "unreadable" }
        let aaguid = String(decoding: bytes[(at + 37)..<(at + 53)].prefix { $0 != 0 }, as: UTF8.self)
        return aaguid == "appattestdevelop" ? "development" : aaguid == "appattest" ? "production" : "unknown (\(aaguid))"
    }
    #endif
}

#if DEBUG
/// `--show-reading-service`: the service offered where App Attest is not (the simulator), to look at Settings. Any
/// attempt to use it fails, as an unsupported device's would.
struct ShownOnlyAttester: AppAttesting {
    var isSupported: Bool { true }
    func generateKey() async throws -> String { throw AppAttestFailure.other("this build only shows the service; App Attest needs a device") }
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data { throw AppAttestFailure.unsupported }
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data { throw AppAttestFailure.unsupported }
}
#endif
