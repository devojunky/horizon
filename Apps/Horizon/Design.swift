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
    /// The accent for words: on light paper the orange itself reads at about 1.7:1, so text in it is set in a deeper
    /// amber (4.7:1, HIG's 4.5:1 for text); at night the orange already reads at about 10:1 and stays. Marks, rings,
    /// fills and the tint keep `accent`.
    static let accentInk = dynamic(light: (0.659, 0.353, 0.0), dark: (1.0, 0.68, 0.26), increased: (light: (0.55, 0.27, 0.0), dark: (1.0, 0.76, 0.42)))
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

    /// `short`: without the weekday, for a row with no room for it ("Sep 2, 12:00 PM").
    static func due(_ date: Date?, hasTime: Bool, short: Bool = false) -> String {
        guard let date else { return "Date TBA" }
        if short { return hasTime ? date.formatted(.dateTime.month(.abbreviated).day().hour().minute()) : date.formatted(.dateTime.month(.abbreviated).day()) }
        return hasTime ? date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
                       : date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    /// A colour with a light and a dark face, and optionally the faces Increase Contrast asks for.
    private static func dynamic(light: (Double, Double, Double), dark: (Double, Double, Double),
                                increased: (light: (Double, Double, Double), dark: (Double, Double, Double))? = nil) -> Color {
        #if canImport(UIKit)
        Color(uiColor: UIColor { trait in
            let high = trait.accessibilityContrast == .high
            let c = trait.userInterfaceStyle == .dark ? (high ? increased?.dark : nil) ?? dark : (high ? increased?.light : nil) ?? light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
        #else
        Color(nsColor: NSColor(name: nil) { appearance in
            let high = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            let darkFace = appearance.bestMatch(from: [.darkAqua, .aqua, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua]).map { $0 == .darkAqua || $0 == .accessibilityHighContrastDarkAqua } ?? false
            let c = darkFace ? (high ? increased?.dark : nil) ?? dark : (high ? increased?.light : nil) ?? light
            return NSColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
        #endif
    }

    /// The masthead: serif titles in every navigation bar (iOS), sized with the user's text size like the system's own
    /// (a page title never smaller than the words under it). Called at launch and again when the text size changes, on
    /// the main actor like every appearance proxy; a bar made after a change takes the new size.
    @MainActor static func installAppearance() {
        #if canImport(UIKit)
        func serif(_ size: CGFloat, _ weight: UIFont.Weight, _ style: UIFont.TextStyle, largest: CGFloat) -> UIFont {
            let base = UIFont.systemFont(ofSize: size, weight: weight)
            let font = base.fontDescriptor.withDesign(.serif).map { UIFont(descriptor: $0, size: size) } ?? base
            return UIFontMetrics(forTextStyle: style).scaledFont(for: font, maximumPointSize: largest)
        }
        let bar = UINavigationBar.appearance()
        bar.largeTitleTextAttributes = [.font: serif(34, .bold, .largeTitle, largest: 58)]
        bar.titleTextAttributes = [.font: serif(17, .semibold, .headline, largest: 30)]
        if !observingSize {
            observingSize = true
            NotificationCenter.default.addObserver(forName: UIContentSizeCategory.didChangeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { installAppearance() }
            }
        }
        #endif
    }
    @MainActor private static var observingSize = false
}

/// A button's own frame, 9 points taller above and below and 3 wider either side: 44 from a small capsule, without
/// reaching into a neighbour 10 points away.
struct Reach: Shape {
    func path(in rect: CGRect) -> Path { Path(rect.insetBy(dx: -3, dy: -9)) }
}

extension String {
    /// A name opening a sentence, its first letter capitalised: a document's tidied file name ("sample syllabus") would
    /// otherwise start the sentence in lower case.
    var sentenceStart: String { prefix(1).uppercased() + dropFirst() }
}

extension View {
    /// A small inline button (Retry, Try Again, Confirm) that is still a full control to hit: its capsule stays small
    /// (about 27 points on iOS) and its hit region reaches the HIG's 44, above and below, so nothing on the page moves.
    func reachable() -> some View {
        #if os(iOS)
        contentShape(.interaction, Reach())
        #else
        self
        #endif
    }

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

/// A section of a page with its kicker as the header (the iOS course page). A Mac's plain list would pin such a
/// header on a band of window grey, off the paper: a Mac page sets its kickers as rows or in its own columns.
struct PageSection<Content: View>: View {
    let kicker: String
    @ViewBuilder var content: Content

    init(_ kicker: String, @ViewBuilder content: () -> Content) {
        self.kicker = kicker; self.content = content()
    }

    var body: some View {
        Section { content } header: { Kicker(kicker) }
    }
}

/// A caps kicker over a headline or a section.
struct Kicker: View {
    let text: String
    var accent = false
    init(_ text: String, accent: Bool = false) { self.text = text; self.accent = accent }
    var body: some View {
        Text(text).font(.caption).textCase(.uppercase).kerning(1).foregroundStyle(accent ? Design.accentInk : .secondary)
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
