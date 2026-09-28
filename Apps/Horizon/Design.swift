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
    static let paper = dynamic(light: (0.976, 0.965, 0.941), dark: (0.082, 0.078, 0.071))
    /// A sheet laid on the page: form cells, chips.
    static let card = dynamic(light: (1.0, 0.996, 0.988), dark: (0.145, 0.139, 0.128))
    /// Hairline rules.
    static let rule = Color.primary.opacity(0.16)
    /// Where a page's words begin and end: 20 points in from its column's edges, the inset of a Mac toolbar's title
    /// and of iOS's own margins. Every row, header and deck on a page starts on this line.
    static let margin: CGFloat = 20
    /// What a plain list pads its rows by at either side, outside any insets they ask for: 8 points on a Mac
    /// (measured), none on iOS.
    #if os(macOS)
    static let listPadding: CGFloat = 8
    #else
    static let listPadding: CGFloat = 0
    #endif

    static func points(_ value: Double?) -> Text {
        guard let value else { return Text("") }
        let figure = Text(value, format: .number.precision(.fractionLength(0...1))).monospacedDigit()
        let sign = Text("%").foregroundStyle(quiet)
        return Text("\(figure)\(sign)")
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

    /// The masthead: serif titles in every navigation bar (iOS). Called once at launch, on the main actor like every appearance proxy.
    @MainActor static func installAppearance() {
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
    /// A row or a section on the paper: no cell colour of its own, hairline separators. Row modifiers only take
    /// effect on rows and sections, never on the List, so every section of a plain list on the paper carries this.
    /// On a Mac a list's rows are clear already (a row background would paint over the selection highlight), and air
    /// parts the rows instead of rules: a Mac list draws its separators from the words to the list's far edge, past
    /// the margin, which reads as unfinished (HIG: group with negative space first).
    func onPaper() -> some View {
        #if os(macOS)
        listRowSeparator(.hidden)
        #else
        listRowBackground(Color.clear).listRowSeparatorTint(Design.rule)
        #endif
    }

    /// A row of a plain list set on the page's margins (`Design.margin`), with `top` and `bottom` of air: its words
    /// start where the page's title does, on either platform. A Mac's list gives a row its top inset below it as well
    /// (measured), so there the air is the row's own padding and the insets are the sides alone.
    func pageRow(top: CGFloat = 10, bottom: CGFloat = 10) -> some View {
        let side = Design.margin - Design.listPadding
        #if os(macOS)
        return padding(.top, top).padding(.bottom, bottom)
            .listRowInsets(EdgeInsets(top: 0, leading: side, bottom: 0, trailing: side))
        #else
        return listRowInsets(EdgeInsets(top: top, leading: side, bottom: bottom, trailing: side))
        #endif
    }

    /// A row on the page's margins on a Mac; iOS keeps its list's own insets, which are already on its margins.
    func macRow(top: CGFloat = 6, bottom: CGFloat = 6) -> some View {
        #if os(macOS)
        pageRow(top: top, bottom: bottom)
        #else
        self
        #endif
    }

    /// A row that runs from one edge of the list to the other, whatever the list pads its rows by (the strip, which
    /// keeps its own margins inside).
    func bleedRow() -> some View {
        listRowInsets(EdgeInsets(top: 0, leading: -Design.listPadding, bottom: 0, trailing: -Design.listPadding))
    }
}

/// A section of a page with a kicker over it. On iOS the kicker is the section's header; on a Mac it is the section's
/// first row, since a plain list there pins a header on a band of window grey with a rule under it, off the paper.
struct PageSection<Content: View>: View {
    let kicker: String
    var accent = false
    /// Air above the kicker on a Mac, where it parts this section from the one before.
    var spacing: CGFloat = 28
    @ViewBuilder var content: Content

    init(_ kicker: String, accent: Bool = false, spacing: CGFloat = 28, @ViewBuilder content: () -> Content) {
        self.kicker = kicker; self.accent = accent; self.spacing = spacing; self.content = content()
    }

    var body: some View {
        #if os(macOS)
        Section {
            Kicker(kicker, accent: accent).pageRow(top: spacing, bottom: 4).selectionDisabled().accessibilityAddTraits(.isHeader)
            content
        }
        #else
        Section { content } header: { Kicker(kicker, accent: accent) }
        #endif
    }
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
