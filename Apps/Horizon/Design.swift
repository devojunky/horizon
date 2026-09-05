import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The look (SPEC §9, leaned into): an editorial page. Warm paper, ink, hairline rules, serif display type under caps
/// kickers, confident numerals, and one accent (a marker orange) used only for weight and urgency. It follows the
/// system appearance (the user asked for no forced dark mode), so every colour here has a light and a dark face.
enum Design {
    static let accent = Color(red: 1.0, green: 0.68, blue: 0.26)
    static let accentSoft = accent.opacity(0.16)
    static let quiet = Color.secondary
    /// The page behind everything.
    static let paper = dynamic(light: (0.976, 0.965, 0.941), dark: (0.094, 0.090, 0.082))
    /// A sheet laid on the page: form cells, chips.
    static let card = dynamic(light: (1.0, 0.996, 0.988), dark: (0.145, 0.139, 0.128))
    /// Hairline rules.
    static let rule = Color.primary.opacity(0.16)

    static func points(_ value: Double?) -> Text {
        guard let value else { return Text("") }
        return Text(value, format: .number.precision(.fractionLength(0...1))).monospacedDigit() + Text("%").foregroundStyle(quiet)
    }

    static func due(_ date: Date?, hasTime: Bool) -> String {
        guard let date else { return "Date TBA" }
        return hasTime ? date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
                       : date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    private static func dynamic(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        #if canImport(UIKit)
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(red: dark.0, green: dark.1, blue: dark.2, alpha: 1) : UIColor(red: light.0, green: light.1, blue: light.2, alpha: 1)
        })
        #else
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(red: dark.0, green: dark.1, blue: dark.2, alpha: 1) : NSColor(red: light.0, green: light.1, blue: light.2, alpha: 1)
        })
        #endif
    }

    /// The masthead: serif titles in every navigation bar (iOS). Called once at launch.
    static func installAppearance() {
        #if canImport(UIKit)
        func serif(_ size: CGFloat, _ weight: UIFont.Weight) -> UIFont {
            let base = UIFont.systemFont(ofSize: size, weight: weight)
            return base.fontDescriptor.withDesign(.serif).map { UIFont(descriptor: $0, size: size) } ?? base
        }
        let bar = UINavigationBar.appearance()
        bar.largeTitleTextAttributes = [.font: serif(34, .bold)]
        bar.titleTextAttributes = [.font: serif(17, .semibold)]
        #endif
    }
}

extension View {
    /// Headline set like a magazine deck: serif, large, tight.
    func deck() -> some View { font(.system(.title2, design: .serif, weight: .semibold)) }
    /// The biggest line on a page.
    func display() -> some View { font(.system(.largeTitle, design: .serif, weight: .bold)) }
    /// A big figure.
    func numeral() -> some View { font(.system(.title, design: .serif, weight: .semibold)).monospacedDigit() }
    /// The page: paper behind a list or a form, the system background hidden.
    func paper() -> some View { scrollContentBackground(.hidden).background(Design.paper.ignoresSafeArea()) }
}

/// A caps kicker over a headline or a section.
struct Kicker: View {
    let text: String
    var accent = false
    init(_ text: String, accent: Bool = false) { self.text = text; self.accent = accent }
    var body: some View {
        Text(text).font(.caption).textCase(.uppercase).kerning(1).foregroundStyle(accent ? Design.accent : .secondary)
    }
}

/// A hairline rule.
struct Hairline: View {
    var body: some View { Rectangle().fill(Design.rule).frame(height: 0.5) }
}

/// An empty state set like a page: a serif line, a deck, and the actions that lead out of it.
struct EditorialEmpty<Actions: View>: View {
    let title: String
    let deck: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).display().fixedSize(horizontal: false, vertical: true)
            Text(deck).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) { actions }.padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 24)
        .accessibilityElement(children: .contain)
    }
}

/// Something is happening: a spinner with a kicker and a line, set like the rest of the page.
struct WorkingLine: View {
    let kicker: String
    let line: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Kicker(kicker)
            HStack(spacing: 12) {
                ProgressView()
                Text(line).deck().fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }
}
