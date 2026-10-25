import FoundationModels

/// The device's own model, Apple Intelligence, as Settings and onboarding speak of it: whether this device can read
/// and plan by itself. Read in a view, it redraws as it changes (`SystemLanguageModel` is observable): Apple
/// Intelligence turned on in Settings, or its model done downloading.
public enum DeviceModel: String, Sendable, CaseIterable {
    /// Ready to read and plan.
    case ready
    /// Apple Intelligence is turned off in Settings: a document for the device waits until it is on.
    case off
    /// Turned on, its model still downloading: a document for the device waits until it is ready.
    case downloading
    /// This device does not support Apple Intelligence: nothing is read or planned by a model of its own.
    case unsupported

    /// One instance, kept: a view observes the instance it read.
    private static let model = SystemLanguageModel.default

    public static var current: DeviceModel {
        switch model.availability {
        case .available: .ready
        case .unavailable(.appleIntelligenceNotEnabled): .off
        case .unavailable(.modelNotReady): .downloading
        case .unavailable: .unsupported
        }
    }

    /// The device supports Apple Intelligence, on or not: reading here is the user's to choose.
    public var supported: Bool { self != .unsupported }
}
