import Foundation

/// Which Claude reads and plans. Ids as the Messages API names them.
public enum ClaudeModelChoice: String, Codable, Sendable, CaseIterable, Identifiable {
    case sonnet5 = "claude-sonnet-5"
    case opus5 = "claude-opus-5"
    case haiku45 = "claude-haiku-4-5"

    public var id: String { rawValue }
    public static let `default` = ClaudeModelChoice.sonnet5

    public var displayName: String {
        switch self { case .sonnet5: "Sonnet 5"; case .opus5: "Opus 5"; case .haiku45: "Haiku 4.5" }
    }
    /// One line on what the choice trades.
    public var detail: String {
        switch self {
        case .sonnet5: "The default: fast, and exact with tables and pictures."
        case .opus5: "The most capable; slower and dearer per document."
        case .haiku45: "The quickest and cheapest."
        }
    }
    /// Whether `output_config.effort` may be sent: Haiku 4.5 rejects it.
    var acceptsEffort: Bool { self != .haiku45 }
}

/// The user's own Claude credential and model. The key is the app's to keep (the Keychain); IngestKit only sends it.
public struct ClaudeConfiguration: Sendable, Equatable {
    public var apiKey: String
    public var model: ClaudeModelChoice
    public var baseURL: URL
    public init(apiKey: String, model: ClaudeModelChoice = .default, baseURL: URL = URL(string: "https://api.anthropic.com/v1")!) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines); self.model = model; self.baseURL = baseURL
    }
}
