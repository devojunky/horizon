import Foundation
import HorizonCore
import IngestKit
#if canImport(DeviceCheck)
import DeviceCheck
#endif

/// The device's side of Horizon's reading service (IngestKit's `ReadingService`; Server/; DECISIONS 2026-10-23 · The
/// reading service in the app): App Attest through `DCAppAttestService`, the attested key's id in the Keychain, and
/// where the service is for this build (`HorizonReadingService` in Info.plist, from Base.xcconfig: the development
/// service for Debug builds, production for Release, each matching the build's App Attest environment).
extension AppModel {
    /// The service this device can read through, or nil: not configured, not offered here (the simulator, a Mac, where
    /// App Attest is not), or a scratch run, which keeps no Keychain item of its own. `--show-reading-service` (DEBUG)
    /// offers one whose every attestation fails, to look at Settings where App Attest is not.
    static let readingService: ReadingService? = {
        guard scratchStore == nil, let text = Bundle.main.object(forInfoDictionaryKey: "HorizonReadingService") as? String,
              let url = URL(string: text), let host = url.host(), url.scheme == "https" else { return nil }
        let log: @Sendable (String) -> Void = { message in Task { @MainActor in AppModel.log(message) } }
        #if DEBUG
        if CommandLine.arguments.contains("--show-reading-service") {
            return ReadingService(serviceURL: url, attester: ShownOnlyAttester(), keys: KeychainAttestedKey(host: host), log: log)
        }
        #endif
        #if os(iOS)
        guard DeviceAttester().isSupported else { return nil }
        return ReadingService(serviceURL: url, attester: DeviceAttester(), keys: KeychainAttestedKey(host: host), log: log)
        #else
        return nil   // App Attest is the service's only way to know a device, and the Mac build does not carry it yet
        #endif
    }()
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

#if os(iOS)
/// App Attest itself, its failures in the classes the service acts on.
struct DeviceAttester: AppAttesting {
    var isSupported: Bool { DCAppAttestService.shared.isSupported }

    func generateKey() async throws -> String {
        try await classed { try await DCAppAttestService.shared.generateKey() }
    }

    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        try await classed { try await DCAppAttestService.shared.attestKey(keyId, clientDataHash: clientDataHash) }
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
}
#endif

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
