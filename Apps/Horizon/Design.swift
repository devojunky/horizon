import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The look (SPEC §9, leaned into): an editorial page. Warm paper, ink, hairline rules, serif display type under caps
/// kickers, confident numerals, and one accent (a marker orange) for weight and urgency, and for the app's selection and
/// controls. It follows the system appearance (the user asked for no forced dark mode), so every colour here has a
/// light and a dark face.
enum Design {
    static let accent = Color(red: 1.0, green: 0.68, blue: 0.26)
    static let accentSoft = accent.opacity(0.16)
    /// The accent for words: on light paper the orange itself reads at about 1.7:1, so text in it is set in a deeper
    /// amber (4.7:1, HIG's 4.5:1 for text); at night the orange already reads at about 10:1 and stays. It is also the
    /// tint (and the asset's AccentColor); marks, rings and fills keep `accent`.
    static let accentInk = dynamic(light: (0.659, 0.353, 0.0), dark: (1.0, 0.68, 0.26), increased: (light: (0.55, 0.27, 0.0), dark: (1.0, 0.76, 0.42)))
    /// Words on a fill of the accent (a prominent button's, `prominent()`): the paper's dark face, about 10:1 on the
    /// orange by day and at night. White there reads at about 1.9:1.
    static let onAccent = Color(red: 0.082, green: 0.078, blue: 0.071)
    /// Words on a tint of the accent (a bordered button's bezel, `bordered()`): the same ink by day, 15:1 on the orange's
    /// tint where the amber read 3.7:1 on its own; at night the accent's words (`accentInk`'s faces), on a tint gone dark.
    static let onAccentTint = dynamic(light: (0.082, 0.078, 0.071), dark: (1.0, 0.68, 0.26), increased: (light: (0.082, 0.078, 0.071), dark: (1.0, 0.76, 0.42)))
    /// The accent where the system sets white words on it and nothing else can be set there: the amber by day and at
    /// night (white on it 5.1:1; 7.1:1 in the deeper amber Increase Contrast asks for). A Mac's swipe action is one.
    static let accentDeep = dynamic(light: (0.659, 0.353, 0.0), dark: (0.659, 0.353, 0.0), increased: (light: (0.55, 0.27, 0.0), dark: (0.55, 0.27, 0.0)))
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
        let sign = Text("%").foregroundStyle(.rowSecondary)
        return Text("\(figure)\(sign)")
    }

    /// `short`: without the weekday, for a row with no room for it ("Sep 2, 12:00 PM").
    static func due(_ date: Date?, hasTime: Bool, short: Bool = false) -> String {
        guard let date else { return "Date TBA" }
        if short { return hasTime ? date.formatted(.dateTime.month(.abbreviated).day().hour().minute()) : date.formatted(.dateTime.month(.abbreviated).day()) }
        return hasTime ? date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
                       : date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    /// "Calculus II · Thu, Oct 9 · 2%": what a row says under an item's name, in the app, Siri's snippets and
    /// Spotlight. Here rather than on `ItemEntity`: a call to the entity's own static from the Mac search page's rows
    /// crashed Xcode 27.0's type checker ("type binding has invalid type").
    static func itemLine(course: String?, due: Date?, hasTime: Bool, weight: Double?) -> String {
        [course, due.map { Self.due($0, hasTime: hasTime) } ?? "No date yet", weight.map { "\($0.formatted(.number.precision(.fractionLength(0...1))))%" }]
            .compactMap { $0 }.joined(separator: " · ")
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
    /// (a page title never smaller than the words under it). Called at launch, whenever the app becomes active, and when
    /// the text size changes, on the main actor like every appearance proxy. The proxy reaches only bars made after it
    /// is set, so the bars already on screen are given the fonts too: on an iPhone 16 Pro Max the first tab's bar came
    /// up in the system font while the tabs opened later had the serif, which the simulator never showed.
    @MainActor static func installAppearance() {
        #if canImport(UIKit)
        func serif(_ size: CGFloat, _ weight: UIFont.Weight, _ style: UIFont.TextStyle, largest: CGFloat) -> UIFont {
            let base = UIFont.systemFont(ofSize: size, weight: weight)
            let font = base.fontDescriptor.withDesign(.serif).map { UIFont(descriptor: $0, size: size) } ?? base
            return UIFontMetrics(forTextStyle: style).scaledFont(for: font, maximumPointSize: largest)
        }
        let large = serif(34, .bold, .largeTitle, largest: 58), inline = serif(17, .semibold, .headline, largest: 30)
        let bar = UINavigationBar.appearance()
        bar.largeTitleTextAttributes = [.font: large]
        bar.titleTextAttributes = [.font: inline]
        func bars(in view: UIView) -> [UINavigationBar] { (view as? UINavigationBar).map { [$0] } ?? view.subviews.flatMap(bars) }
        for window in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows) {
            for bar in bars(in: window) {
                bar.largeTitleTextAttributes = (bar.largeTitleTextAttributes ?? [:]).merging([.font: large]) { $1 }
                bar.titleTextAttributes = (bar.titleTextAttributes ?? [:]).merging([.font: inline]) { $1 }
            }
        }
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

    /// A page's prominent action (DECISIONS 2026-10-25 · Prominent buttons): the orange filled, by day and at night (a
    /// fill is the accent's; the amber tint is for words), its words in `Design.onAccent`.
    func prominent() -> some View {
        buttonStyle(.borderedProminent).tint(Design.accent).modifier(OnAccent(ink: Design.onAccent))
    }

    /// A page's other actions (Edit, Try Again, Cancel; DECISIONS 2026-10-25 · The accent under words and glyphs): the
    /// orange's tint for a bezel, a step quieter than `prominent()`, its words in `Design.onAccentTint`, ink by day. A
    /// Mac draws them as `macInk()` says.
    func bordered() -> some View {
        #if os(macOS)
        buttonStyle(.bordered).macInk()
        #else
        buttonStyle(.bordered).tint(Design.accent).modifier(OnAccent(ink: Design.onAccentTint))
        #endif
    }

    /// A button a Mac draws bordered whatever its style (in a form, a sheet's foot, a page): `bordered()` there. iOS
    /// keeps its own, a form's row of the tint's words.
    func macBordered() -> some View {
        #if os(macOS)
        bordered()
        #else
        self
        #endif
    }

    /// A control a Mac draws with its words in its tint, whatever the words are given: a bordered button, a form's
    /// pop-up picker. The amber's words read 4.4:1 on a form's card by day (the orange's, 1.7:1), so there the tint is
    /// the words' own colour, `Design.onAccentTint`; the bezel the Mac lays under them is a twentieth of it, near the
    /// paper. iOS keeps the app's tint.
    func macInk() -> some View {
        #if os(macOS)
        tint(Design.onAccentTint)
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

    /// A row on the paper that opens a page beside its list, marked while that page is the one open there (HIG: keep
    /// the selection highlighted in the pane that leads to the detail): the accent's soft fill, the app's selection.
    /// Where the page is pushed over the list instead (a compact width) nothing is ever marked.
    func onPaper(selected: Bool) -> some View {
        #if os(macOS)
        listRowSeparator(.hidden)
        #else
        listRowBackground(selected ? Design.accentSoft : Color.clear).listRowSeparatorTint(Design.rule)
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

/// A button's words in `ink` while it shows the accent: a prominent button's fill, whose words iOS and a Mac's toolbar
/// set white whatever the fill (a Mac's page sets dark words on a light fill by itself), or a bordered button's tint,
/// whose words the system sets in the tint itself. A disabled button, and on a Mac a button in a window that is not
/// key, is drawn grey by the system with words of its own, and keeps them: ink set there all but vanished on the grey
/// at night.
private struct OnAccent: ViewModifier {
    let ink: Color
    @Environment(\.isEnabled) private var isEnabled
    #if os(macOS)
    @Environment(\.controlActiveState) private var window
    private var filled: Bool { isEnabled && window == .key }
    #else
    private var filled: Bool { isEnabled }
    #endif

    func body(content: Content) -> some View {
        if filled { content.foregroundStyle(ink) } else { content }
    }
}

/// Quiet or accent words in a row that can be selected: their own style, and the selection's on a row the system
/// highlights (`backgroundProminence` increased), as Finder's and Mail's columns turn white there. The secondary style
/// is white at about 70% on a selected row, 4.3:1 on a Mac table's selection by day and 2.2:1 on the orange at night;
/// the amber's words all but vanished on it.
struct OnSelection<Base: ShapeStyle>: ShapeStyle {
    let base: Base
    func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
        environment.backgroundProminence == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(base)
    }
}

extension ShapeStyle where Self == OnSelection<HierarchicalShapeStyle> {
    static var rowSecondary: Self { OnSelection(base: .secondary) }
    static var rowTertiary: Self { OnSelection(base: .tertiary) }
}

extension ShapeStyle where Self == OnSelection<Color> {
    /// `Design.accentInk`'s words in a row (a document that failed).
    static var rowAccent: Self { OnSelection(base: Design.accentInk) }
}

/// A row's own swipe action on the accent (Done, Confirm), as a prominent button is: on iOS the orange with its glyph in
/// `Design.onAccent`, by day and at night. iOS draws a swipe action as a circle of its tint with the glyph on it, white
/// whatever the tint, and takes no foreground style from the button (white on the orange read at 1.9:1 at night); a
/// symbol in palette mode keeps the colour it is given. A Mac sets the action's words in white itself, so there the
/// fill is `Design.accentDeep`.
struct AccentSwipe: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    init(_ title: String, systemImage: String, action: @escaping () -> Void) {
        self.title = title; self.systemImage = systemImage; self.action = action
    }

    var body: some View {
        #if os(iOS)
        Button(action: action) {
            Label { Text(title) } icon: { Image(systemName: systemImage).symbolRenderingMode(.palette).foregroundStyle(Design.onAccent) }
        }
        .tint(Design.accent)
        #else
        Button(title, systemImage: systemImage, action: action).tint(Design.accentDeep)
        #endif
    }
}

/// Buttons side by side at one width, the widest label's (HIG: tell buttons apart by style, not size). Its ideal width
/// is that many of the widest, so in a `ViewThatFits` it gives way to a stack when they would not all fit whole: an
/// `HStack` of flexible buttons measured each label alone, fitted, then halved the row and cut "Mark Not Done".
struct EqualWidths: Layout {
    var spacing: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let count = CGFloat(subviews.count)
        let widest = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        let width = proposal.width ?? widest * count + spacing * (count - 1)
        let each = max((width - spacing * (count - 1)) / count, 0)
        let height = subviews.map { $0.sizeThatFits(ProposedViewSize(width: each, height: nil)).height }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let count = CGFloat(subviews.count)
        let each = max((bounds.width - spacing * (count - 1)) / count, 0)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + CGFloat(index) * (each + spacing), y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: each, height: bounds.height))
        }
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

/// A kicker over a block of a page's side column (a Mac's course page and Now; Now on iPhone Duo open and an iPad).
struct RailSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Kicker(title).accessibilityAddTraits(.isHeader)
            content
        }
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

#if os(iOS)
/// A bar button's words where bars run along the top and the bottom, as the app sets them; where a bar stands at the
/// display's edge (iPhone Duo closed, and open in landscape) the same button as a symbol with the words as its title.
/// An item of words alone keeps a bar horizontal there, and costs a band across the top of the short outer display
/// (HIG: minimize text buttons; give every item a title and a symbol, which overflow and VoiceOver use).
struct BarLabel: View {
    let title: String
    let systemImage: String

    init(_ title: String, systemImage: String) {
        self.title = title; self.systemImage = systemImage
    }

    var body: some View {
        if #available(iOS 27.1, *) { Edged(title: title, systemImage: systemImage) } else { Text(title) }
    }

    @available(iOS 27.1, *)
    private struct Edged: View {
        let title: String, systemImage: String
        @Environment(\.toolbarVerticalEdge) private var edge   // nil where a bar never stands at the edge
        var body: some View {
            if edge == nil { Text(title) } else { Label(title, systemImage: systemImage) }
        }
    }
}

extension View {
    /// Whether this page's bar stands at the display's edge (iPhone Duo closed, and open in landscape), kept in
    /// `vertical`: a page leaves out of its toolbar what only a horizontal bar can hold, which would otherwise keep a
    /// horizontal bar across the top for itself alone.
    func readsVerticalBar(_ vertical: Binding<Bool>) -> some View {
        modifier(VerticalBarReader(vertical: vertical))
    }
}

private struct VerticalBarReader: ViewModifier {
    @Binding var vertical: Bool
    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) { content.modifier(Reading(vertical: $vertical)) } else { content }
    }

    @available(iOS 27.1, *)
    private struct Reading: ViewModifier {
        @Binding var vertical: Bool
        @Environment(\.toolbarVerticalEdge) private var edge
        func body(content: Content) -> some View {
            content.onChange(of: edge != nil, initial: true) { _, standing in vertical = standing }
        }
    }
}
#endif

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
