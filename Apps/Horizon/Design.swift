import SwiftUI

/// SPEC §9: editorial, one accent used only for weight and urgency, confident numbers. Follows the system appearance
/// (the user asked for no forced dark mode), so every color here is semantic and works in both schemes.
enum Design {
    static let accent = Color(red: 1.0, green: 0.68, blue: 0.26)
    static let quiet = Color.secondary

    static func points(_ value: Double?) -> Text {
        guard let value else { return Text("") }
        return Text(value, format: .number.precision(.fractionLength(0...1))).monospacedDigit() + Text("%").foregroundStyle(quiet)
    }

    static func due(_ date: Date?, hasTime: Bool) -> String {
        guard let date else { return "Date TBA" }
        return hasTime ? date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
                       : date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}

extension View {
    /// Headline set like a magazine deck: serif, large, tight.
    func deck() -> some View { font(.system(.title2, design: .serif, weight: .semibold)) }
}
