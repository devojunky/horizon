import Foundation

/// Which Claude reads and plans. Ids as the Messages API names them; the cases name the line, not the version, so a
/// stored choice and a saved shortcut outlive the next bump.
public enum ClaudeModelChoice: String, Codable, Sendable, CaseIterable, Identifiable {
    case sonnet = "claude-sonnet-5-5"
    case opus = "claude-opus-5-5"
    case haiku = "claude-haiku-5-5"

    public var id: String { rawValue }
    public static let `default` = ClaudeModelChoice.sonnet

    /// A choice as stored in settings, an older model's id taken as its line's current one.
    public init?(stored: String) {
        if let choice = ClaudeModelChoice(rawValue: stored) { self = choice; return }
        switch stored {
        case "claude-sonnet-5": self = .sonnet
        case "claude-opus-5": self = .opus
        case "claude-haiku-4-5": self = .haiku
        default: return nil
        }
    }

    public var displayName: String {
        switch self { case .sonnet: "Sonnet 5.5"; case .opus: "Opus 5.5"; case .haiku: "Haiku 5.5" }
    }
    /// One line on what the choice trades.
    public var detail: String {
        switch self {
        case .sonnet: "The default: fast, and exact with tables and pictures."
        case .opus: "The most capable; slower and dearer per document."
        case .haiku: "The quickest and cheapest."
        }
    }
    /// What `thinking` to send to keep the model from thinking, if it can be kept from it at that effort: Sonnet 5.5
    /// takes `between_tools` (no tools here, so no thinking; `disabled` is a 400), Haiku 5.5 `disabled`, each at high or
    /// below (a 400 at xhigh and max). Opus 5.5 always thinks: nothing turns it off, and the effort is lowered instead
    /// (`effort(for:)`).
    func thinkingOff(atEffort effort: String) -> String? {
        guard ["low", "medium", "high"].contains(effort) else { return nil }
        switch self {
        case .sonnet: return "between_tools"
        case .haiku: return "disabled"
        case .opus: return nil
        }
    }
    /// The effort sent for a request: Opus 5.5, which cannot be told not to think, thinks least at low.
    func effort(for request: ClaudeClient.Request) -> String {
        self == .opus && request.thinking == .off ? "low" : request.effort
    }
}

/// Who a request goes out as: the user's own key, straight to Anthropic, or this device through Horizon's reading
/// service (Server/, DECISIONS 2026-10-23 · The tester proxy), which proves itself with App Attest and holds no key of
/// the user's.
public enum ClaudeCredential: Sendable, Equatable {
    case apiKey(String)
    case service(any ClaudeRequestSigner)

    public static func == (a: ClaudeCredential, b: ClaudeCredential) -> Bool {
        switch (a, b) {
        case (.apiKey(let x), .apiKey(let y)): x == y
        case (.service(let x), .service(let y)): x.serviceURL == y.serviceURL
        default: false
        }
    }
}

/// What sends a request through Horizon's reading service: it attaches this device's proof (an App Attest assertion
/// over the request's own bytes) and sends it. `ReadingService` is the one there is; tests have their own.
public protocol ClaudeRequestSigner: Sendable {
    /// The service's API root: its Messages API is `messages` under it, as Anthropic's is under `/v1`.
    var serviceURL: URL { get }
    /// Sends `request` with the device's proof, through `transport`.
    func send(_ request: URLRequest, through transport: ClaudeTransport) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, any Error>)
    /// Lets go of the device's key, for one the service no longer knows: the next request attests a new one.
    func renew() async
}

/// The Claude a read or a plan goes to, and which model. A key is the app's to keep (the Keychain); IngestKit only sends it.
public struct ClaudeConfiguration: Sendable, Equatable {
    public var credential: ClaudeCredential
    public var model: ClaudeModelChoice
    public var baseURL: URL
    public init(apiKey: String, model: ClaudeModelChoice = .default, baseURL: URL = URL(string: "https://api.anthropic.com/v1")!) {
        self.credential = .apiKey(apiKey.trimmingCharacters(in: .whitespacesAndNewlines)); self.model = model; self.baseURL = baseURL
    }
    /// Through Horizon's reading service. The model is the service's, Sonnet 5.5 (its `MODEL`): the request is written
    /// for it, so that the thinking it is told to leave off is that model's way of saying so.
    public init(service: any ClaudeRequestSigner) {
        self.credential = .service(service); self.model = .sonnet; self.baseURL = service.serviceURL
    }

    /// The user's key, or empty through the service.
    public var apiKey: String { if case .apiKey(let key) = credential { key } else { "" } }
    public var usesService: Bool { if case .service = credential { true } else { false } }
    /// Whether a request can go out at all: a key, or the service.
    public var isUsable: Bool { usesService || !apiKey.isEmpty }
}

/// Printed or interpolated anywhere (a log line, a debugger), the configuration never shows its key.
extension ClaudeConfiguration: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        usesService ? "ClaudeConfiguration(\(model.rawValue), through \(baseURL.host() ?? baseURL.absoluteString))"
                    : "ClaudeConfiguration(\(model.rawValue), key of \(apiKey.count) characters)"
    }
    public var debugDescription: String { description }
}
