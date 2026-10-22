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

/// The user's own Claude credential and model. The key is the app's to keep (the Keychain); IngestKit only sends it.
public struct ClaudeConfiguration: Sendable, Equatable {
    public var apiKey: String
    public var model: ClaudeModelChoice
    public var baseURL: URL
    public init(apiKey: String, model: ClaudeModelChoice = .default, baseURL: URL = URL(string: "https://api.anthropic.com/v1")!) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines); self.model = model; self.baseURL = baseURL
    }
}

/// Printed or interpolated anywhere (a log line, a debugger), the configuration never shows its key.
extension ClaudeConfiguration: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "ClaudeConfiguration(\(model.rawValue), key of \(apiKey.count) characters)" }
    public var debugDescription: String { description }
}
