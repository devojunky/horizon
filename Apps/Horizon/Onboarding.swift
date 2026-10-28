#if os(iOS)
import SwiftUI
import HorizonCore

/// The first launch on an iPhone or iPad with nothing on file (DECISIONS 2026-10-25 · Onboarding): four short pages
/// under one stage where Horizon's icon comes alive. The horizon is drawn, the sun rises from behind it and the term's
/// marks stand up on it; then a syllabus is read onto that horizon, its deadlines go to Reminders, and a missing week is
/// noticed. Where the device supports Apple Intelligence a fifth page says so and offers the one choice onboarding
/// makes, already made: read on the device, or with Claude (DECISIONS 2026-10-25 · Your iPhone supports Apple
/// Intelligence). Every mark lands with a tap as strong as its weight. Swipe or Continue, Skip on any page, a tap on the
/// stage plays it again. Nothing is asked for here: Reminders access waits until there is something to write.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.horizontalSizeClass) private var sizeClass
    let finish: () -> Void
    @State private var page: Int
    @State private var replay = 0
    @State private var leaving = false
    @State private var stageGone = false
    @State private var gone = false
    @State private var begun = 0
    /// Bars stand at the display's edge here (iPhone Duo closed): the display is short, so Skip leaves its own row for the
    /// stage's top corner, as the system moves a page's controls to the side to give its content the height.
    @State private var barsStand = false
    /// What the words and the controls under the stage need on the page with the most of them, at the text size in use:
    /// with the choice of reader, its two cards (538 points at the default size, measured on iPhone Duo closed, about a
    /// 6.1-inch iPhone's width); without it, `cardsRoom` less. On a short display the stage gives way to them, so both
    /// readers show without a scroll (iPhone Duo closed, the smaller iPhones); on a Pro Max the stage's own proportion is
    /// the limit, as before.
    @ScaledMetric(relativeTo: .body) private var wordsRoom: CGFloat = 544   // with a little to spare
    @ScaledMetric(relativeTo: .body) private var cardsRoom: CGFloat = 184

    init(startPage: Int = 0, finish: @escaping () -> Void) {
        _page = State(initialValue: min(max(startPage, 0), Self.offersChoice ? 4 : 3))
        self.finish = finish
    }

    /// The choice of reader is offered where the device supports Apple Intelligence, on or not yet; where it does not,
    /// Claude is the only reader and there is nothing to choose. Whether it is supported never changes while the app runs.
    private static var offersChoice: Bool { AppModel.deviceModel.supported }

    private struct Page { let kicker: String, title: String, deck: String, aside: String?, scene: OnboardingScene }

    private var pages: [Page] {
        let device = AppModel.deviceKind
        let reads: String
        if model.readRoute == .onDevice {
            reads = "It's read right on your \(device), so nothing leaves it, and every date is checked against the page itself."
        } else if model.usesReadingService {
            reads = "Claude reads it through Horizon's server, which keeps none of it, and every date is checked against the page itself."
        } else if model.claudeConfiguration != nil {
            reads = "Claude reads it with your key, and every date is checked against the page itself."
        } else {
            reads = "Claude reads it once you add a key in Settings, and every date is checked against the page itself."
        }
        var pages = [
            Page(kicker: "Horizon", title: "The whole term, on one horizon.",
                 deck: "Horizon reads your course documents and keeps every deadline in view, weighed by what it is worth.", aside: nil, scene: .term),
            Page(kicker: "Reading", title: "Share a syllabus. Horizon reads it.",
                 deck: "A PDF, a schedule, a photo of a printed page. \(reads)", aside: Self.offersChoice ? nil : "Who reads is yours to choose in Settings.", scene: .read),
            Page(kicker: "Reminders", title: "Every deadline, in Reminders.",
                 deck: "They go to a list called Horizon, so they still remind you if you never open the app. Check one off there and Horizon knows.", aside: nil, scene: .remind),
            Page(kicker: "Coverage", title: "And it notices what is missing.",
                 deck: "A weekly quiz with none on file next week, a course gone quiet while work fell due: Coverage says so before it costs you.", aside: nil, scene: .notice),
        ]
        if Self.offersChoice {
            pages.append(Page(kicker: "Your choice", title: "Your \(device) supports Apple Intelligence.",
                              deck: "So it can read every syllabus itself, and not a word leaves your \(device). Switch any time in Settings.",   // the two cards under it are the choice: the words do not narrate them
                              aside: nil, scene: .choose))
        }
        return pages
    }

    private var last: Int { pages.count - 1 }

    var body: some View {
        Group {
            if #available(iOS 27.1, *), sizeClass == .regular { besideLayout } else { column }
        }
        // The page's own paper goes last, once nothing is drawn on it, so the app comes in on the same paper: a fade
        // through, never the stage over the app at half strength.
        .background(Design.paper.opacity(gone ? 0 : 1).ignoresSafeArea())
        .tint(Design.accentInk)
        .sensoryFeedback(.selection, trigger: page)
        .sensoryFeedback(.success, trigger: begun)
        .readsVerticalBar($barsStand)
    }

    /// A phone (and iPhone Duo closed): the stage over the words, Continue under them, where the thumb is.
    private var column: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                if !barsStand { skipRow }
                stage
                    .frame(maxWidth: 440)
                    .frame(height: stageHeight(in: proxy.size, skipRow: !barsStand))
                    .padding(.horizontal, Design.margin)
                pager
                footer
            }
            .frame(maxWidth: .infinity)
            .overlay(alignment: .topTrailing) { if barsStand { skipButton } }
        }
    }

    /// With room (iPhone Duo open, an iPad): the stage on one side and the words with their controls on the other,
    /// rather than a column down the middle (HIG: with more room, expand the layout). An arrangement, so folded like a
    /// book each has a half of the display and the scene never plays across the fold; propped like a laptop, the scene
    /// is on the raised half and Continue on the half that lies flat (HIG: content for a distance on top, controls below).
    @available(iOS 27.1, *)
    private var besideLayout: some View {
        ArrangementView {
            stage
                .frame(maxWidth: 560)
                .padding(Design.margin)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } secondary: {
            VStack(spacing: 0) {
                pager
                footer
            }
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .arrangementViewStyle(.split)
        // In the display's top corner, not a row of its own: propped like a laptop the words have only the flat half,
        // and the choice of reader needs all of it.
        .overlay(alignment: .topTrailing) { skipButton }
    }

    /// Skip in a row of its own over the stage (a phone).
    private var skipRow: some View {
        HStack {
            Spacer()
            skipButton
        }
    }

    /// Skip, at the page's trailing margin, 44 points high: hidden on the last page, where Begin is the way on.
    private var skipButton: some View {
        Button("Skip") { close(begin: false) }
            .foregroundStyle(.secondary)
            .opacity(page < last ? 1 : 0)
            .disabled(page >= last || leaving)
            .reachable()
            .frame(height: 44)
            .padding(.horizontal, Design.margin)
    }

    private var stage: some View {
        OnboardingStage(scene: pages[min(page, last)].scene, replay: replay, leaving: leaving, claude: model.readRoute == .claude)
            .opacity(stageGone ? 0 : 1)
            .contentShape(Rectangle())
            .onTapGesture { if !leaving { replay += 1 } }   // the scene again: a way to look at it, not a control to find
            .accessibilityHidden(true)
    }

    /// The pages' words, swiped through.
    private var pager: some View {
        let pages = pages
        return TabView(selection: $page) {
            ForEach(pages.indices, id: \.self) { index in
                PageText(kicker: pages[index].kicker, title: pages[index].title, deck: pages[index].deck, aside: pages[index].aside,
                         choice: pages[index].scene == .choose).tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .opacity(leaving ? 0 : 1)
    }

    /// Where the pages are, and Continue (Begin on the last).
    private var footer: some View {
        VStack(spacing: 18) {
            HStack(spacing: 7) {
                ForEach(pages.indices, id: \.self) { index in
                    Capsule().fill(index == page ? Design.accent : Design.rule).frame(width: index == page ? 22 : 7, height: 7)
                }
            }
            .animation(reduceMotion ? nil : .snappy, value: page)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Page \(page + 1) of \(pages.count)")

            Button {
                if page < last { withAnimation(.snappy) { page += 1 } } else { close(begin: true) }
            } label: {
                Text(page < last ? "Continue" : "Begin").font(.headline).frame(maxWidth: .infinity).frame(minHeight: 30)
            }
            .prominent()
            .controlSize(.large)
            .frame(maxWidth: 440)
            .disabled(leaving)
        }
        .padding(.horizontal, Design.margin)
        .padding(.bottom, 12)
        .opacity(leaving ? 0 : 1)
    }

    /// The stage's height: its own proportion at the width it has, less on a short screen (landscape) and at the
    /// accessibility text sizes, where the words need the room, and never more than leaves the words what they need
    /// (`wordsRoom`).
    private func stageHeight(in size: CGSize, skipRow: Bool) -> CGFloat {
        let width = min(size.width - 2 * Design.margin, 440)
        let natural = width * OnboardingStage.aspect
        let share: CGFloat = typeSize.isAccessibilitySize ? 0.24 : 0.36
        let words = wordsRoom - (Self.offersChoice ? 0 : cardsRoom) + (skipRow ? 44 : 0)
        return max(100, min(natural, size.height * share, size.height - words))   // never so small the scene cannot be read
    }

    /// Begin (or Skip): the words go as the sun lifts, then the stage, then the paper, and the app it was laid over is
    /// there on the same paper.
    private func close(begin: Bool) {
        guard !leaving else { return }
        if begin { begun += 1 }
        let lifted: Double = reduceMotion || !begin ? 0 : 0.5   // only Begin waits for the sun
        withAnimation(.easeInOut(duration: reduceMotion ? 0.25 : 0.4)) { leaving = true }
        withAnimation(.easeIn(duration: 0.3).delay(lifted)) { stageGone = true }
        withAnimation(.easeOut(duration: 0.3).delay(lifted + 0.3)) { gone = true }
        let after = lifted + 0.65
        Task {
            try? await Task.sleep(for: .seconds(after))
            var quiet = Transaction()
            quiet.disablesAnimations = true   // already transparent: the cover goes without sliding away
            withTransaction(quiet) { finish() }
        }
    }
}

/// One page's words, set like the app's pages: a kicker, the display serif, a deck, on the margin's line; on the choice
/// page, the two readers under them.
private struct PageText: View {
    let kicker: String, title: String, deck: String
    let aside: String?
    let choice: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 12) {
                    Kicker(kicker, accent: true)
                    Text(title).display().fixedSize(horizontal: false, vertical: true)
                    Text(deck).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let aside { Text(aside).font(.footnote).foregroundStyle(.secondary).padding(.top, 2).fixedSize(horizontal: false, vertical: true) }
                }
                .accessibilityElement(children: .combine)   // the words read as one; the choice's buttons stay buttons
                if choice { ReaderChoice().padding(.top, 4) }
            }
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Design.margin)
            .padding(.top, 18)
            .padding(.bottom, 8)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

/// The choice page's two readers, the one on file chosen: this iPhone's (or iPad's) own model, Apple Intelligence, or
/// Claude. A tap chooses, as Settings' Read Documents does, and the stage turns to the one chosen. On the device it is
/// the user's to choose even while Apple Intelligence is off or still downloading (a document then waits for it);
/// Claude needs Horizon's server or a key.
private struct ReaderChoice: View {
    @Environment(AppModel.self) private var model
    private let device = AppModel.deviceKind

    private var onDevice: Bool { model.readRoute == .onDevice }

    private var deviceDetail: String {
        switch model.deviceModel {
        case .off: "Turn on Apple Intelligence in the Settings app first."
        case .downloading: "Ready once Apple Intelligence finishes downloading."
        default: "Slower, and less sure of tables and pictures."   // private, the deck has said
        }
    }

    private var claudeDetail: String {
        if model.usesReadingService { return "Sharpest with tables and pictures. Sent to Anthropic through Horizon's server." }
        if model.claudeConfiguration != nil { return "Sharpest with tables and pictures. Sent to Anthropic under your key." }
        return "Needs a key, in Settings."
    }

    var body: some View {
        // Side by side where each has room for its words in a line or two (the flat half of iPhone Duo propped like a
        // laptop, an iPad), so both show on a short pane; one over the other where they have not (a phone, iPhone Duo
        // closed). A card asks for 240 points beside the other; given more, it takes it.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 10) { options(side: true) }
                .fixedSize(horizontal: false, vertical: true)   // the two as tall as the taller
            VStack(spacing: 10) { options(side: false) }
        }
        .sensoryFeedback(.selection, trigger: onDevice)
        .animation(.snappy, value: onDevice)
    }

    @ViewBuilder private func options(side: Bool) -> some View {
        option("On This \(device)", detail: deviceDetail, selected: onDevice, side: side) { model.readingRoute = .onDevice }
        option("Claude", detail: claudeDetail, selected: !onDevice, disabled: model.claudeConfiguration == nil, side: side) { model.readingRoute = .claude }
    }

    private func option(_ title: String, detail: String, selected: Bool, disabled: Bool = false, side: Bool, choose: @escaping () -> Void) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14)
        return Button(action: choose) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline).foregroundStyle(disabled ? .secondary : .primary)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? AnyShapeStyle(Design.accent) : AnyShapeStyle(Design.rule))
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: side ? .infinity : nil, alignment: .topLeading)
            .frame(idealWidth: side ? 240 : nil)
            .background(Design.card, in: shape)
            .overlay(shape.strokeBorder(selected ? AnyShapeStyle(Design.accent) : AnyShapeStyle(Design.rule), lineWidth: selected ? 1.5 : 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The scenes, one per page: the four every device sees, and where Apple Intelligence is supported the choice.
enum OnboardingScene: Int { case term, read, remind, notice, choose }

/// The stage: the app's icon in its own coordinates (a 1024-point square: the sun at 512, 468 with a radius of 204,
/// the horizon a bar from 116 to 908 at 642, seven ink marks standing on it), seen through a window from 150 to 770 so
/// there is room above the horizon for a page, its reminders, a week, the device and the cloud. Each scene is a
/// choreography of states, run in order and cancelled by the next; with Reduce Motion each arrives whole, by a fade.
struct OnboardingStage: View {
    let scene: OnboardingScene
    let replay: Int
    let leaving: Bool
    /// The reader on file, for the choice's scene: Claude (the cloud lit, a page sent up to it) or the device.
    let claude: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(scene: OnboardingScene, replay: Int, leaving: Bool, claude: Bool = false) {
        self.scene = scene; self.replay = replay; self.leaving = leaving; self.claude = claude
        _claudeChosen = State(initialValue: claude)   // right from the first run, before any change has been seen
        _fold = State(initialValue: Self.lastFold)
    }

    nonisolated static let top: CGFloat = 150
    static let aspect: CGFloat = 620 / 1024

    // The horizon, the sun.
    @State private var horizon: CGFloat = 0
    @State private var sun: CGFloat = 0
    @State private var sunDim: Double = 1
    @State private var lift: CGFloat = 0
    @State private var glow = false
    // What each scene lays on it.
    @State private var iconLayer: Double = 0
    @State private var iconMarks = Array(repeating: CGFloat(0), count: 7)
    @State private var termLayer: Double = 0
    @State private var termMarks = Array(repeating: CGFloat(0), count: 4)
    @State private var readLayer: Double = 0
    @State private var cardOffset: CGFloat = 0
    @State private var beam: CGFloat = 0
    @State private var beamShown: Double = 0
    @State private var chips = Array(repeating: false, count: 4)
    @State private var drops = Array(repeating: CGFloat(0), count: 4)
    @State private var dropShown = Array(repeating: false, count: 4)
    @State private var rowsLayer: Double = 0
    @State private var rows = Array(repeating: CGFloat(0), count: 3)
    @State private var checked: CGFloat = 0
    @State private var weekLayer: Double = 0
    @State private var weeks = Array(repeating: CGFloat(0), count: 6)
    @State private var gap: CGFloat = 0
    @State private var gapPulse = false
    // The choice: the device rising in front of the sun and reading on its own screen, and the cloud beside it.
    @State private var chooseLayer: Double = 0
    @State private var deviceRise: CGFloat = 0
    @State private var screenLit: Double = 0
    @State private var screenBeam: CGFloat = 0
    @State private var screenBeamShown: Double = 0
    @State private var screenChips = Array(repeating: false, count: 2)
    @State private var cloudShown: CGFloat = 0
    @State private var arc: CGFloat = 0
    @State private var toCloud: CGFloat = 0
    @State private var travel: CGFloat = 0
    @State private var travelShown = false
    @State private var claudeChosen: Bool   // `claude` as it is now: a running choreography sees the view it began with
    @State private var sends = 0
    /// Where the device has a hinge (iPhone Duo), its opening as drawn, 0 closed to 1 open flat; nil where it has none,
    /// and the slab is drawn.
    @State private var fold: Double?
    /// The last opening read, for a stage made afresh: the page's layout changes as iPhone Duo opens and closes, the
    /// stage is made again in the new one, and its device swings from where it was rather than starting where it is.
    private static var lastFold: Double?
    @State private var shown: OnboardingScene?
    @State private var lastReplay = 0
    // Haptics: each a counter, its strength riding with it.
    @State private var tap = Tap()
    @State private var crest = Tap()
    @State private var knock = Tap()
    @State private var checks = 0

    struct Tap: Equatable {
        var count = 0
        var intensity = 0.5
        mutating func fire(_ strength: Double) { count += 1; intensity = min(1, max(0.1, strength)) }
    }

    private struct Run: Hashable { let scene: OnboardingScene; let replay: Int }

    // The icon's marks: centres and heights, standing on 658.
    private static let iconX: [CGFloat] = [230, 326, 422, 518, 614, 710, 806]
    private static let iconH: [CGFloat] = [72, 118, 86, 158, 76, 132, 58]
    // A syllabus's four dated lines, the days they land on and what each is worth.
    private static let datedLines = [1, 3, 4, 6]
    private static let termX: [CGFloat] = [262, 418, 612, 768]
    private static let termH: [CGFloat] = [64, 150, 96, 122]
    private static let termPoints: [Double] = [6, 32, 14, 22]
    // A week by week rhythm, the fifth week missing.
    private static let weekX: [CGFloat] = [236, 346.4, 456.8, 567.2, 677.6, 788]
    private static let missing = 4

    // The page sits above the tallest mark's head (492), so what it throws down stands in full beneath it.
    private static func lineY(_ k: Int) -> CGFloat { 198 + 40 * CGFloat(k) }
    private static let cardY: CGFloat = 320, cardWidth: CGFloat = 400, cardHeight: CGFloat = 300
    private static let beamFrom: CGFloat = 180, beamTo: CGFloat = 460, sweep = 1.8, fall = 0.42
    // The device the user holds, standing on the horizon in front of the sun, its foot behind the bar: an iPhone with
    // its Dynamic Island, or an iPad with its camera. The cloud sits up and to the right, clear of the sun.
    private static let isPad = AppModel.deviceKind == "iPad"
    private static let device: CGSize = isPad ? CGSize(width: 290, height: 372) : CGSize(width: 204, height: 372)
    nonisolated private static let deviceFoot: CGFloat = 654
    private static var deviceTop: CGFloat { deviceFoot - device.height }
    private static let bezel: CGFloat = isPad ? 18 : 14
    nonisolated private static let screenLines: [CGFloat] = [0.94, 0.6, 0.8, 0.48, 0.7]   // of the screen's width; the second and fourth are dated
    private static let cloudFrame = CGRect(x: 724, y: 168, width: 236, height: 128)
    private static var arcFrom: CGPoint { CGPoint(x: 512 + device.width / 2 - 34, y: deviceTop + 40) }
    private static let arcVia = CGPoint(x: 660, y: 176), arcTo = CGPoint(x: 762, y: 262)
    // The screen's rows and the line that reads them, in the device's own units from its top left.
    private static let screenSweep = 1.1
    private static let screenBeamFrom: CGFloat = bezel + 50
    private static var screenBeamTo: CGFloat { device.height - bezel - 40 }
    private static func screenLineY(_ k: Int) -> CGFloat { bezel + 70 + 52 * CGFloat(k) }
    private static func passes(_ k: Int) -> Double { Double((screenLineY(k) - screenBeamFrom) / (screenBeamTo - screenBeamFrom)) }

    var body: some View {
        GeometryReader { proxy in
            let s = proxy.size.width / 1024
            ZStack(alignment: .topLeading) {
                sunView(s)
                chooseView(s).opacity(chooseLayer)
                iconMarksView(s).opacity(iconLayer)
                termMarksView(s).opacity(termLayer)
                weeksView(s).opacity(weekLayer)
                Capsule().fill(.primary)
                    .frame(width: 792 * s, height: 30 * s)
                    .scaleEffect(x: horizon, y: 1, anchor: .center)
                    .position(Self.at(512, 657, s))
                readView(s).opacity(readLayer)
                rowsView(s).opacity(rowsLayer)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .aspectRatio(1 / Self.aspect, contentMode: .fit)
        .task(id: Run(scene: scene, replay: replay)) { await run(scene) }
        .task(id: sends) { if sends > 0 { await send() } }
        .modifier(FollowsHinge { follow($0) })
        .onChange(of: claude, initial: true) { old, now in
            claudeChosen = now
            // The reader chosen on the page: the stage turns to it, and a page goes up to the cloud when it is Claude.
            guard old != now, shown == .choose, scene == .choose, !leaving else { return }
            withAnimation(reduceMotion ? .easeInOut(duration: 0.25) : .snappy(duration: 0.45)) { toCloud = now ? 1 : 0; sunDim = now ? 0.5 : 1 }
            if now, !reduceMotion, cloudShown >= 1 { sends += 1 }
        }
        .onChange(of: leaving) { _, now in
            guard now else { return }
            if reduceMotion { return }
            withAnimation(.easeInOut(duration: 0.7)) { lift = 1; sunDim = 1; iconLayer = 0; termLayer = 0; readLayer = 0; rowsLayer = 0; weekLayer = 0; chooseLayer = 0 }
        }
        .sensoryFeedback(trigger: tap) { _, new in .impact(weight: .light, intensity: new.intensity) }
        .sensoryFeedback(trigger: crest) { _, new in .impact(flexibility: .soft, intensity: new.intensity) }
        .sensoryFeedback(trigger: knock) { _, new in .impact(flexibility: .rigid, intensity: new.intensity) }
        .sensoryFeedback(.success, trigger: checks)
    }

    // MARK: Drawing

    static func at(_ x: CGFloat, _ y: CGFloat, _ s: CGFloat) -> CGPoint { CGPoint(x: x * s, y: (y - top) * s) }

    /// The sun, glass orange, risen from behind the horizon (clipped at its lower edge) and breathing a little at rest.
    private func sunView(_ s: CGFloat) -> some View {
        Circle()
            .fill(RadialGradient(colors: [Color(red: 1.0, green: 0.83, blue: 0.58), Design.accent], center: UnitPoint(x: 0.36, y: 0.30), startRadius: 0, endRadius: 270 * s))
            .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 3 * s).blendMode(.plusLighter))
            .frame(width: 408 * s, height: 408 * s)
            .shadow(color: Design.accent.opacity(glow ? 0.55 : 0.32), radius: (glow ? 46 : 30) * s)
            .scaleEffect(1 + 0.16 * lift)
            .position(Self.at(512, 468 + (1 - sun) * 480 - lift * 110, s))
            .opacity(sunDim)
            .mask(alignment: .top) { Rectangle().frame(height: (672 - Self.top) * s) }
    }

    private func bar(x: CGFloat, height: CGFloat, grow: CGFloat, _ s: CGFloat) -> some View {
        let h = height * max(0, grow)
        return RoundedRectangle(cornerRadius: 12 * s).frame(width: 36 * s, height: h * s).position(Self.at(x, 658 - h / 2, s))
    }

    private func iconMarksView(_ s: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<7, id: \.self) { i in bar(x: Self.iconX[i], height: Self.iconH[i], grow: iconMarks[i], s).foregroundStyle(.primary) }
        }
    }

    /// The syllabus's deadlines on the term, each in the strip's colour for what it is worth.
    private func termMarksView(_ s: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<4, id: \.self) { i in
                bar(x: Self.termX[i], height: Self.termH[i], grow: termMarks[i], s)
                    .foregroundStyle(Design.accent.opacity(Strip.heat(points: Self.termPoints[i])))
            }
        }
    }

    private func weeksView(_ s: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<6, id: \.self) { i in
                if i != Self.missing { bar(x: Self.weekX[i], height: 92, grow: weeks[i], s).foregroundStyle(Design.accent.opacity(Strip.heat(points: 16))) }
            }
            RoundedRectangle(cornerRadius: 12 * s)
                .strokeBorder(Design.accent, style: StrokeStyle(lineWidth: 5 * s, dash: [10 * s, 8 * s]))
                .frame(width: 36 * s, height: 92 * s)
                .scaleEffect(gapPulse ? 1.09 : 1, anchor: .bottom)
                .opacity(Double(gap))
                .scaleEffect(0.6 + 0.4 * gap, anchor: .bottom)
                .position(Self.at(Self.weekX[Self.missing], 612, s))
            Text("Quiz 5?")
                .font(.system(size: max(11, 30 * s), weight: .semibold))
                .foregroundStyle(Design.accentInk)
                .fixedSize()
                .opacity(Double(gap))
                .position(Self.at(Self.weekX[Self.missing], 536 - 14 * gap, s))
        }
    }

    /// A syllabus, read by a sweeping line; each dated line it passes throws its date down onto the horizon.
    private func readView(_ s: CGFloat) -> some View {
        let card = RoundedRectangle(cornerRadius: 30 * s)
        return ZStack(alignment: .topLeading) {
            card.fill(Design.card)
                .overlay(card.strokeBorder(Design.rule, lineWidth: 2 * s))
                .shadow(color: .black.opacity(0.08), radius: 18 * s, y: 8 * s)
                .frame(width: Self.cardWidth * s, height: Self.cardHeight * s)
                .position(Self.at(512, Self.cardY + cardOffset, s))
            ForEach(0..<7, id: \.self) { k in
                let dated = Self.datedLines.firstIndex(of: k)
                let widths: [CGFloat] = [270, 160, 300, 150, 200, 230, 130]
                let start: CGFloat = dated == nil ? 350 : 432
                Capsule().fill(Color.primary.opacity(0.14))
                    .frame(width: widths[k] * s, height: 16 * s)
                    .position(Self.at(start + widths[k] / 2, Self.lineY(k) + cardOffset, s))
                if let dated {
                    Capsule().fill(Design.accent)
                        .frame(width: 64 * s, height: 22 * s)
                        .scaleEffect(chips[dated] ? 1.18 : 1)
                        .position(Self.at(382, Self.lineY(k) + cardOffset, s))
                }
            }
            LinearGradient(colors: [Design.accent.opacity(0), Design.accent.opacity(0.22)], startPoint: .top, endPoint: .bottom)
                .frame(width: Self.cardWidth * s, height: 70 * s)
                .overlay(alignment: .bottom) { Rectangle().fill(Design.accent).frame(height: 4 * s) }
                .position(Self.at(512, Self.beamFrom + (Self.beamTo - Self.beamFrom) * beam - 35, s))
                .opacity(beamShown)
                .mask { card.frame(width: Self.cardWidth * s, height: Self.cardHeight * s).position(Self.at(512, Self.cardY + cardOffset, s)) }
            ForEach(0..<4, id: \.self) { i in
                Circle().fill(Design.accent)
                    .frame(width: 26 * s, height: 26 * s)
                    .modifier(Along(progress: drops[i], from: Self.at(382, Self.lineY(Self.datedLines[i]), s), to: Self.at(Self.termX[i], 640, s)))
                    .opacity(dropShown[i] ? 1 : 0)
            }
        }
    }

    /// Three reminders rising from the horizon; the first is checked off.
    private func rowsView(_ s: CGFloat) -> some View {
        let titles: [CGFloat] = [250, 300, 220], subtitles: [CGFloat] = [120, 150, 100]
        return ZStack(alignment: .topLeading) {
            ForEach(0..<3, id: \.self) { i in
                let y = 222 + 104 * CGFloat(i) + (1 - rows[i]) * 70
                let row = RoundedRectangle(cornerRadius: 24 * s)
                row.fill(Design.card)
                    .overlay(row.strokeBorder(Design.rule, lineWidth: 2 * s))
                    .shadow(color: .black.opacity(0.06), radius: 12 * s, y: 5 * s)
                    .frame(width: 520 * s, height: 92 * s)
                    .position(Self.at(512, y, s))
                    .opacity(Double(rows[i]))
                ZStack {
                    Circle().strokeBorder(Design.accent, lineWidth: 6 * s)
                    if i == 0 {
                        Circle().fill(Design.accent).scaleEffect(checked)
                        Check().trim(from: 0, to: checked).stroke(Design.paper, style: StrokeStyle(lineWidth: 6 * s, lineCap: .round, lineJoin: .round))
                    }
                }
                .frame(width: 48 * s, height: 48 * s)
                .position(Self.at(302, y, s))
                .opacity(Double(rows[i]))
                Capsule().fill(Color.primary.opacity(i == 0 ? 0.14 - 0.07 * checked : 0.14))
                    .frame(width: titles[i] * s, height: 16 * s)
                    .position(Self.at(348 + titles[i] / 2, y - 13, s))
                    .opacity(Double(rows[i]))
                Capsule().fill(Color.primary.opacity(0.08))
                    .frame(width: subtitles[i] * s, height: 12 * s)
                    .position(Self.at(348 + subtitles[i] / 2, y + 16, s))
                    .opacity(Double(rows[i]))
            }
        }
    }

    /// The choice: the device the user holds, risen in front of the sun and reading a page on its own screen; the cloud
    /// up and to the right with a dotted way to it. The reader chosen is lit: the screen and the sun behind it, or the
    /// cloud and its way. On iPhone Duo the device folds with its hinge (`foldingView`).
    @ViewBuilder private func chooseView(_ s: CGFloat) -> some View {
        if let fold { foldingView(s, fold: fold) } else { slabView(s) }
    }

    /// The dotted way from the device's top right corner up to the cloud.
    private func way(_ s: CGFloat, from: CGPoint, via: CGPoint) -> some View {
        Arc(from: Self.at(from.x, from.y, s), via: Self.at(via.x, via.y, s), to: Self.at(Self.arcTo.x, Self.arcTo.y, s))
            .trim(from: 0, to: arc)
            .stroke(Design.accent.opacity(0.3 + 0.7 * Double(toCloud)), style: StrokeStyle(lineWidth: 6 * s, lineCap: .round, dash: [0.5, 16 * s]))
    }

    private func cloud(_ s: CGFloat) -> some View {
        Cloud().fill(Design.card)
            .overlay(Cloud().fill(Design.accent.opacity(0.14 * Double(toCloud))))
            .overlay(Cloud().stroke(Design.rule, lineWidth: 3 * s))
            .overlay(Cloud().stroke(Design.accent, lineWidth: 4 * s).opacity(Double(toCloud)))
            .shadow(color: .black.opacity(0.07), radius: 14 * s, y: 6 * s)
            .frame(width: Self.cloudFrame.width * s, height: Self.cloudFrame.height * s)
            .position(Self.at(Self.cloudFrame.midX + (1 - cloudShown) * 80, Self.cloudFrame.midY, s))
            .opacity(Double(cloudShown) * (0.55 + 0.45 * Double(toCloud)))
    }

    /// A page going up the way to the cloud, and back read, when Claude reads.
    private func traveler(_ s: CGFloat, from: CGPoint, via: CGPoint) -> some View {
        Circle().fill(Design.accent)
            .frame(width: 26 * s, height: 26 * s)
            .modifier(Along(progress: travel, from: Self.at(from.x, from.y, s), to: Self.at(Self.arcTo.x, Self.arcTo.y, s), via: Self.at(via.x, via.y, s)))
            .opacity(travelShown ? 1 : 0)
    }

    /// An iPhone (with its Dynamic Island) or an iPad (with its camera), a slab standing on the horizon.
    private func slabView(_ s: CGFloat) -> some View {
        let size = Self.device
        let rise = (1 - deviceRise) * (size.height + 24)
        let shell = RoundedRectangle(cornerRadius: (Self.isPad ? 38 : 56) * s)
        let screen = RoundedRectangle(cornerRadius: (Self.isPad ? 22 : 44) * s)
        let screenW = (size.width - 2 * Self.bezel) * s, screenH = (size.height - 2 * Self.bezel) * s
        let middle = CGPoint(x: size.width / 2 * s, y: size.height / 2 * s)
        let margin: CGFloat = Self.isPad ? 30 : 22
        let inner = size.width - 2 * Self.bezel - 2 * margin
        let here = Double(1 - toCloud)
        return ZStack(alignment: .topLeading) {
            way(s, from: Self.arcFrom, via: Self.arcVia)
            cloud(s)
            traveler(s, from: Self.arcFrom, via: Self.arcVia)
            ZStack(alignment: .topLeading) {
                shell.fill(.primary).frame(width: size.width * s, height: size.height * s)
                Group {
                    screen.fill(Design.card)
                    screen.fill(RadialGradient(colors: [Design.accent.opacity(0.45), Design.accent.opacity(0)], center: UnitPoint(x: 0.5, y: 0.08), startRadius: 0, endRadius: screenH * 0.9))
                        .opacity(0.3 + 0.7 * here)
                }
                .frame(width: screenW, height: screenH)
                .position(middle)
                .opacity(screenLit)
                ForEach(0..<5, id: \.self) { k in
                    let chip: Int? = k == 1 ? 0 : k == 3 ? 1 : nil
                    let start = Self.bezel + margin + (chip == nil ? 0 : 40)
                    let width = (inner - (chip == nil ? 0 : 40)) * Self.screenLines[k]
                    Capsule().fill(Color.primary.opacity(0.14))
                        .frame(width: width * s, height: 14 * s)
                        .position(x: (start + width / 2) * s, y: Self.screenLineY(k) * s)
                        .opacity(screenLit)
                    if let chip {
                        Capsule().fill(Design.accent.opacity(screenChips[chip] ? 1 : 0.3))
                            .frame(width: 30 * s, height: 18 * s)
                            .scaleEffect(screenChips[chip] ? 1.14 : 1)
                            .position(x: (Self.bezel + margin + 15) * s, y: Self.screenLineY(k) * s)
                            .opacity(screenLit)
                    }
                }
                LinearGradient(colors: [Design.accent.opacity(0), Design.accent.opacity(0.22)], startPoint: .top, endPoint: .bottom)
                    .frame(width: screenW, height: 54 * s)
                    .overlay(alignment: .bottom) { Rectangle().fill(Design.accent).frame(height: 4 * s) }
                    .position(x: middle.x, y: (Self.screenBeamFrom + (Self.screenBeamTo - Self.screenBeamFrom) * screenBeam - 27) * s)
                    .opacity(screenBeamShown)
                    .mask { screen.frame(width: screenW, height: screenH).position(middle) }
                if Self.isPad {
                    Circle().fill(Design.paper.opacity(0.35)).frame(width: 8 * s, height: 8 * s).position(x: middle.x, y: Self.bezel / 2 * s)
                } else {
                    Capsule().fill(.primary).frame(width: 62 * s, height: 20 * s).position(x: middle.x, y: (Self.bezel + 22) * s)
                }
            }
            .frame(width: size.width * s, height: size.height * s)
            .position(Self.at(512, Self.deviceFoot - size.height / 2 + rise, s))
        }
        .mask(alignment: .top) { Rectangle().frame(height: (672 - Self.top) * s) }   // risen from behind the horizon, as the sun is
    }

    /// iPhone Duo as it is held (`Fold`), redrawn every frame of a swing so the way to the cloud keeps to its corner.
    /// With Reduce Motion it is closed or open, and one gives way to the other by a fade through, the cloud staying put.
    private func foldingView(_ s: CGFloat, fold: Double) -> some View {
        ZStack(alignment: .topLeading) {
            folding(fold) { fold in way(s, from: fold.arcFrom, via: Self.arcVia(from: fold.arcFrom)) }
            cloud(s)
            folding(fold) { fold in
                traveler(s, from: fold.arcFrom, via: Self.arcVia(from: fold.arcFrom))
                foldingDevice(s, fold)
                    .compositingGroup()   // so a fade is the whole device's, not its screen over its shell
                    .offset(y: (1 - deviceRise) * (Fold.panel.height + 40) * s)
            }
        }
        .mask(alignment: .top) { Rectangle().frame(height: (672 - Self.top) * s) }
    }

    /// What follows the fold, drawn at the opening of each frame; made afresh for each shape with Reduce Motion.
    private func folding<Content: View>(_ opening: Double, @ViewBuilder _ content: @escaping (Fold) -> Content) -> some View {
        Folding(opening: opening) { opening in ZStack(alignment: .topLeading) { content(Fold(opening: opening)) } }
            .id(reduceMotion ? opening : -1)
            .transition(.fadeThrough)
    }

    /// The way's bend for a device whose corner is `from`: the slab's, or further right with the device.
    private static func arcVia(from: CGPoint) -> CGPoint { CGPoint(x: max(arcVia.x, from.x + 40), y: arcVia.y) }

    /// The two halves on their crease, each turned and seen from the eye: the right half, then the cover over it, showing
    /// its front (the inner display's left half) or its back (the outer display) as it faces the eye.
    private func foldingDevice(_ s: CGFloat, _ fold: Fold) -> some View {
        let p = Fold.panel
        let middle = Self.deviceFoot - p.height / 2
        let covered = !fold.coverFaces
        return ZStack(alignment: .topLeading) {
            panel(.right, s)
                .position(Self.at(fold.crease + p.width / 2, middle, s))
                .projectionEffect(fold.turning(cover: false, s))
            ZStack {
                panel(.left, s).opacity(covered ? 0 : 1)
                panel(.outer, s).scaleEffect(x: -1).opacity(covered ? 1 : 0)   // seen from behind, so drawn mirrored
            }
            .animation(nil, value: covered)   // it turns over edge on, at once
            .position(Self.at(fold.crease - p.width / 2, middle, s))
            .projectionEffect(fold.turning(cover: true, s))
        }
    }

    /// One face of a half, flat: the shell, the screen (lit, glowing while the device is the reader), the page on it with
    /// its dates lit as the line passes them, the line reading it, and on the outer display its camera. The inner
    /// display's halves meet at the crease with no bezel and a hairline between them; the spine side of the outer one is
    /// square, as Apple draws it.
    private func panel(_ face: Fold.Face, _ s: CGFloat) -> some View {
        let p = Fold.panel, rect = face.screen
        let shell = UnevenRoundedRectangle(cornerRadii: face.radii(Fold.corner * s, spine: 0))
        let screen = UnevenRoundedRectangle(cornerRadii: face.radii(Fold.screenCorner * s, spine: (face == .outer ? 4 : 0) * s))
        let here = Double(1 - toCloud)
        let beamFrom = Fold.lineY(rect, page: 50), beamTo = Fold.lineY(rect, page: 304)
        let lit = ZStack {
            screen.fill(Design.card)
            screen.fill(RadialGradient(colors: [Design.accent.opacity(0.45), Design.accent.opacity(0)], center: face.glow, startRadius: 0, endRadius: rect.height * 0.9 * s))
                .opacity(0.3 + 0.7 * here)
        }
        return ZStack(alignment: .topLeading) {
            shell.fill(.primary).frame(width: p.width * s, height: p.height * s)
            lit.frame(width: rect.width * s, height: rect.height * s)
                .position(x: rect.midX * s, y: rect.midY * s)
                .opacity(screenLit)
            if face != .outer {
                Rectangle().fill(Design.rule)
                    .frame(width: 1.5 * s, height: rect.height * s)
                    .position(x: (face == .left ? rect.maxX - 0.75 : rect.minX + 0.75) * s, y: rect.midY * s)
                    .opacity(screenLit)
            }
            ForEach(0..<5, id: \.self) { k in
                let chip = face.chip(k)
                let start = rect.minX + face.margins.leading + (chip == nil ? 0 : 40)
                let width = (rect.width - face.margins.leading - face.margins.trailing - (chip == nil ? 0 : 40)) * face.lines[k]
                let y = Fold.lineY(rect, page: 70 + 52 * CGFloat(k))
                Capsule().fill(Color.primary.opacity(0.14))
                    .frame(width: width * s, height: 14 * s)
                    .position(x: (start + width / 2) * s, y: y * s)
                    .opacity(screenLit)
                if let chip {
                    Capsule().fill(Design.accent.opacity(screenChips[chip] ? 1 : 0.3))
                        .frame(width: 30 * s, height: 18 * s)
                        .scaleEffect(screenChips[chip] ? 1.14 : 1)
                        .position(x: (rect.minX + face.margins.leading + 15) * s, y: y * s)
                        .opacity(screenLit)
                }
            }
            LinearGradient(colors: [Design.accent.opacity(0), Design.accent.opacity(0.22)], startPoint: .top, endPoint: .bottom)
                .frame(width: rect.width * s, height: 54 * s)
                .overlay(alignment: .bottom) { Rectangle().fill(Design.accent).frame(height: 4 * s) }
                .position(x: rect.midX * s, y: (beamFrom + (beamTo - beamFrom) * screenBeam - 27) * s)
                .opacity(screenBeamShown)
                .mask { screen.frame(width: rect.width * s, height: rect.height * s).position(x: rect.midX * s, y: rect.midY * s) }
            if face == .outer {
                Circle().fill(.primary).frame(width: 18 * s, height: 18 * s).position(x: (rect.maxX - 24) * s, y: (rect.minY + 24) * s)
            }
        }
        .frame(width: p.width * s, height: p.height * s, alignment: .topLeading)
    }

    // MARK: Choreography

    private func run(_ scene: OnboardingScene) async {
        let previous = shown
        let again = previous == scene && replay != lastReplay
        lastReplay = replay
        shown = scene
        let sharesTerm = [OnboardingScene.read, .remind].contains(scene) && [OnboardingScene.read, .remind].contains(previous ?? .term) && !again
        if previous != nil && (previous != scene || again) {
            // What this scene does not share with the last goes first, before anything of its own comes (a fade through).
            withAnimation(.easeOut(duration: 0.18)) {
                iconLayer = 0; readLayer = 0; rowsLayer = 0; weekLayer = 0; chooseLayer = 0
                if !sharesTerm { termLayer = 0 }
            }
            guard await pause(0.18) else { return }
        }
        quietly { gapPulse = false; glow = false; travelShown = false }
        switch scene {
        case .term: await term(again: again)
        case .read: await read()
        case .remind: await remind()
        case .notice: await notice()
        case .choose: await choose()
        }
    }

    private func term(again: Bool) async {
        quietly {
            iconMarks = Array(repeating: 0, count: 7)
            if again { horizon = 0; sun = 0 }
        }
        if reduceMotion {
            quietly { horizon = 1; sun = 1; iconMarks = Array(repeating: 1, count: 7) }
            withAnimation(.easeInOut(duration: 0.4)) { iconLayer = 1; sunDim = 1 }
            crest.fire(0.7)
            return
        }
        quietly { iconLayer = 1 }
        withAnimation(.easeInOut(duration: 0.5)) { sunDim = 1 }
        if horizon < 1 {
            withAnimation(.easeOut(duration: 0.6)) { horizon = 1 }
            guard await pause(0.22) else { return }
        }
        if sun < 1 {
            withAnimation(.spring(duration: 1.25, bounce: 0.16)) { sun = 1 }
            guard await pause(0.42) else { return }
            crest.fire(0.8)   // the sun clears the horizon
            guard await pause(0.42) else { return }
        }
        for i in 0..<7 {
            withAnimation(.spring(duration: 0.5, bounce: 0.42)) { iconMarks[i] = 1 }
            tap.fire(0.25 + 0.65 * Double(Self.iconH[i] / 158))   // as strong as the mark is tall
            guard await pause(0.075) else { return }
        }
        guard await pause(0.6) else { return }
        withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) { glow = true }
    }

    private func read() async {
        quietly {
            horizon = 1; sun = 1
            termMarks = Array(repeating: 0, count: 4); drops = Array(repeating: 0, count: 4); dropShown = Array(repeating: false, count: 4)
            chips = Array(repeating: false, count: 4); beam = 0; beamShown = 0; cardOffset = reduceMotion ? 0 : -26
        }
        if reduceMotion {
            quietly { termMarks = Array(repeating: 1, count: 4) }
            withAnimation(.easeInOut(duration: 0.4)) { sunDim = 0.22; readLayer = 1; termLayer = 1 }
            tap.fire(0.6)
            return
        }
        withAnimation(.easeInOut(duration: 0.5)) { sunDim = 0.22 }
        withAnimation(.spring(duration: 0.6, bounce: 0.18)) { readLayer = 1; cardOffset = 0; termLayer = 1 }
        guard await pause(0.45) else { return }
        withAnimation(.easeOut(duration: 0.2)) { beamShown = 1 }
        withAnimation(.linear(duration: Self.sweep)) { beam = 1 }
        // As the line passes a dated row its date lifts and falls onto its day; where it lands, the deadline stands up.
        enum Moment { case pass(Int), land(Int), done }
        let passes = Self.datedLines.map { Double((Self.lineY($0) - Self.beamFrom) / (Self.beamTo - Self.beamFrom)) * Self.sweep }
        var moments = passes.enumerated().flatMap { [($0.element, Moment.pass($0.offset)), ($0.element + Self.fall, Moment.land($0.offset))] }
        moments.append((Self.sweep + 0.1, .done))
        moments.sort { $0.0 < $1.0 }
        var now = 0.0
        for (time, moment) in moments {
            guard await pause(time - now) else { return }
            now = time
            switch moment {
            case .pass(let i):
                withAnimation(.spring(duration: 0.3, bounce: 0.5)) { chips[i] = true }
                quietly { dropShown[i] = true }
                withAnimation(.easeIn(duration: Self.fall)) { drops[i] = 1 }
            case .land(let i):
                quietly { dropShown[i] = false }
                withAnimation(.spring(duration: 0.5, bounce: 0.45)) { termMarks[i] = 1; chips[i] = false }
                tap.fire(0.2 + 0.75 * Self.termPoints[i] / 32)   // a heavier deadline lands harder
            case .done:
                withAnimation(.easeOut(duration: 0.3)) { beamShown = 0 }
            }
        }
    }

    private func remind() async {
        quietly { horizon = 1; sun = 1; rows = Array(repeating: 0, count: 3); checked = 0; rowsLayer = 1 }
        if reduceMotion {
            quietly { termMarks = Array(repeating: 1, count: 4); rows = Array(repeating: 1, count: 3); rowsLayer = 0 }
            withAnimation(.easeInOut(duration: 0.4)) { sunDim = 0.22; termLayer = 1; rowsLayer = 1 }
            guard await pause(0.5) else { return }
            withAnimation(.easeInOut(duration: 0.3)) { checked = 1 }
            checks += 1
            return
        }
        withAnimation(.easeInOut(duration: 0.5)) { sunDim = 0.22 }
        if termMarks.contains(where: { $0 < 1 }) || termLayer < 1 {
            withAnimation(.spring(duration: 0.5, bounce: 0.3)) { termMarks = Array(repeating: 1, count: 4); termLayer = 1 }
        }
        for i in 0..<3 {
            withAnimation(.spring(duration: 0.6, bounce: 0.24)) { rows[i] = 1 }
            guard await pause(0.12) else { return }
        }
        guard await pause(0.6) else { return }
        withAnimation(.easeInOut(duration: 0.42)) { checked = 1 }
        guard await pause(0.3) else { return }
        checks += 1   // the check lands
    }

    private func notice() async {
        quietly { horizon = 1; sun = 1; weeks = Array(repeating: 0, count: 6); gap = 0; weekLayer = 1 }
        if reduceMotion {
            quietly { weeks = Array(repeating: 1, count: 6); gap = 1; weekLayer = 0 }
            withAnimation(.easeInOut(duration: 0.4)) { sunDim = 0.22; weekLayer = 1 }
            knock.fire(0.55)
            return
        }
        withAnimation(.easeInOut(duration: 0.5)) { sunDim = 0.22 }
        for i in 0..<6 where i != Self.missing {
            withAnimation(.spring(duration: 0.45, bounce: 0.4)) { weeks[i] = 1 }
            tap.fire(0.35)
            guard await pause(0.085) else { return }
        }
        guard await pause(0.4) else { return }
        withAnimation(.spring(duration: 0.55, bounce: 0.35)) { gap = 1 }
        knock.fire(0.6)   // a knock at the week that is not there
        guard await pause(0.14) else { return }
        knock.fire(0.45)
        guard await pause(0.5) else { return }
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { gapPulse = true }
    }

    /// The device rises in front of the sun as the sun rose from behind the horizon, its screen comes on, and it reads a
    /// page right there; then the cloud comes in beside it, and when Claude is the reader a page goes up to it.
    private func choose() async {
        let claude = claudeChosen   // as it is now: a card tapped during the fade before this run is not undone by it
        quietly {
            horizon = 1; sun = 1
            deviceRise = 0; screenLit = 0; screenBeam = 0; screenBeamShown = 0; screenChips = [false, false]
            cloudShown = 0; arc = 0; travel = 0; toCloud = claude ? 1 : 0; chooseLayer = 1
        }
        if reduceMotion {
            quietly { deviceRise = 1; screenLit = 1; screenChips = [true, true]; cloudShown = 1; arc = 1; chooseLayer = 0 }
            withAnimation(.easeInOut(duration: 0.4)) { sunDim = claude ? 0.5 : 1; chooseLayer = 1 }
            crest.fire(0.7)
            return
        }
        withAnimation(.easeInOut(duration: 0.5)) { sunDim = claude ? 0.5 : 1 }
        withAnimation(.spring(duration: 1.1, bounce: 0.14)) { deviceRise = 1 }
        guard await pause(0.5) else { return }
        crest.fire(0.8)   // the device clears the horizon, as the sun did
        withAnimation(.easeOut(duration: 0.5)) { screenLit = 1 }
        guard await pause(0.35) else { return }
        withAnimation(.easeOut(duration: 0.2)) { screenBeamShown = 1 }
        withAnimation(.linear(duration: Self.screenSweep)) { screenBeam = 1 }
        var now = 0.0
        for (i, line) in [1, 3].enumerated() {   // each date it passes lights, a tap on the device itself
            let at = Self.passes(line) * Self.screenSweep
            guard await pause(at - now) else { return }
            now = at
            withAnimation(.spring(duration: 0.35, bounce: 0.5)) { screenChips[i] = true }
            tap.fire(0.4 + 0.25 * Double(i))
        }
        guard await pause(Self.screenSweep - now + 0.05) else { return }
        withAnimation(.easeOut(duration: 0.3)) { screenBeamShown = 0 }
        withAnimation(.spring(duration: 0.7, bounce: 0.2)) { cloudShown = 1 }
        tap.fire(0.3)   // the cloud, lighter
        withAnimation(.easeInOut(duration: 0.6)) { arc = 1 }
        guard await pause(0.6) else { return }
        if claudeChosen { sends += 1 }
        guard await pause(0.4) else { return }
        withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) { glow = true }
    }

    /// A page goes up to the cloud and its dates come back: Claude reading, when Claude is chosen. A choice made again
    /// starts it over.
    private func send() async {
        guard shown == .choose, !reduceMotion else { return }
        quietly { travel = 0; travelShown = true }
        withAnimation(.easeInOut(duration: 0.65)) { travel = 1 }
        guard await pause(0.65), shown == .choose else { quietly { travelShown = false }; return }
        tap.fire(0.5)   // it reaches Claude
        guard await pause(0.3) else { quietly { travelShown = false }; return }
        withAnimation(.easeInOut(duration: 0.65)) { travel = 0 }
        guard await pause(0.65) else { quietly { travelShown = false }; return }
        quietly { travelShown = false }
        if shown == .choose { tap.fire(0.35) }   // and is back, read
    }

    /// The hinge moved, or was read for the first time. The device follows it live: hinge data for an effect, never for
    /// layout (Apple), and nothing here lays anything out. From closed to open, or back, the cover swings all the way
    /// over. With Reduce Motion the device is closed or open, never between (`foldingView` fades one into the other).
    private func follow(_ opening: Double?) {
        guard var opening else { return }   // no hinge: the slab, as on every other device
        if reduceMotion { opening = opening > 0 ? 1 : 0 }
        Self.lastFold = opening
        guard let drawn = fold else { quietly { fold = opening }; return }
        guard drawn != opening else { return }
        let over = (drawn == 0) != (opening == 0)
        withAnimation(reduceMotion ? .easeInOut(duration: 0.3) : over ? .spring(duration: 0.9, bounce: 0.12) : .interactiveSpring(response: 0.22, dampingFraction: 0.9)) {
            fold = opening
        }
    }

    private func pause(_ seconds: Double) async -> Bool {
        guard seconds > 0 else { return !Task.isCancelled }
        do { try await Task.sleep(for: .seconds(seconds)); return true } catch { return false }
    }

    private func quietly(_ change: () -> Void) {
        var quiet = Transaction()
        quiet.disablesAnimations = true
        withTransaction(quiet, change)
    }
}

extension OnboardingStage {
    /// iPhone Duo as it is held (DECISIONS 2026-10-28 · The device folds on iPhone Duo): two halves on a crease, each in
    /// the outer display's proportions (466 by 678 points), side by side open (951 by 669), in the stage's units and seen
    /// from an eye in front of the stage's middle. Apple's own symbols are the model. Closed, the cover faces the eye,
    /// its spine square on the left and its camera in the top right corner (`iphone.duo`). Opening, the cover lifts
    /// toward the eye and swings out to the left; from 60 degrees the halves stand in a V facing the eye
    /// (`iphone.duo.open.partial.landscape`), flat once fully open.
    private struct Fold {
        /// 0 closed to 1 open flat: the hinge's angle over 180 degrees.
        var opening: Double

        static let panel = CGSize(width: 200, height: 286)
        static let bezel: CGFloat = 14, spine: CGFloat = 7
        static let corner: CGFloat = 52, screenCorner: CGFloat = 38
        /// How far the eye is from the stage: near enough that a half turned toward it reads as nearer.
        static let distance: CGFloat = 1100
        private static let eye = CGPoint(x: 512, y: OnboardingStage.deviceFoot - panel.height / 2)

        /// How far the halves are from flat, in radians.
        private var bend: Double { (1 - opening) * .pi }
        /// How far the view has turned toward the cover: none in the V (60 degrees open or more), all of it shut.
        private var toCover: Double {
            let t = max(0, 1 - opening * 3)
            return t * t * (3 - 2 * t)
        }
        /// Each half's turn about the crease, its free edge toward the eye: the right half's, and the cover's.
        private var turnRight: Double { bend / 2 * (1 - toCover) }
        private var turnCover: Double { bend / 2 * (1 + toCover) }
        /// Where the crease stands, so the device is centred under the eye however it is folded.
        var crease: CGFloat { 512 - Self.panel.width / 2 * CGFloat(cos(turnRight) - max(0, cos(turnCover))) }

        /// A point `along` a half from the crease, at the height `y`, as the eye sees it.
        private func seen(along: CGFloat, y: CGFloat, cover: Bool) -> CGPoint {
            let turn = cover ? turnCover : turnRight
            let x = crease + (cover ? -along : along) * CGFloat(cos(turn)), z = along * CGFloat(sin(turn))
            let k = Self.distance / (Self.distance - z)
            return CGPoint(x: Self.eye.x + (x - Self.eye.x) * k, y: Self.eye.y + (y - Self.eye.y) * k)
        }

        /// Whether the cover shows the eye its front, the inner display's left half; else its back, the outer display.
        var coverFaces: Bool { seen(along: Self.panel.width, y: Self.eye.y, cover: true).x < crease }

        /// Where the way to the cloud starts, under the right half's top right corner (the cover's, closed).
        var arcFrom: CGPoint { seen(along: Self.panel.width - 34, y: OnboardingStage.deviceFoot - Self.panel.height + 40, cover: false) }

        /// A half turned about the crease and seen from the eye, for `projectionEffect` on the half laid flat in the
        /// stage's points at the scale `s`.
        func turning(cover: Bool, _ s: CGFloat) -> ProjectionTransform {
            // A point x of the half goes to cx + (x - cx) cos θ and comes (cx - x) sin θ toward the eye, which, d away,
            // sees it larger by d / (d - z): a projective map of the plane.
            let theta = cover ? turnCover : -turnRight
            let d = Self.distance * s, cx = crease * s
            let ex = Self.eye.x * s, ey = (Self.eye.y - OnboardingStage.top) * s
            let sine = CGFloat(sin(theta)) / d, cosine = CGFloat(cos(theta))
            var m = ProjectionTransform()
            m.m11 = cosine + ex * sine; m.m12 = ey * sine; m.m13 = sine
            m.m31 = cx * (1 - cosine - ex * sine); m.m32 = -cx * ey * sine; m.m33 = 1 - cx * sine
            return m
        }

        /// A line of the page `page` points down the iPhone's 344-point screen, on this one: the same share of it, so
        /// the reading line passes the dates at the moments `passes` gives the iPhone.
        static func lineY(_ screen: CGRect, page: CGFloat) -> CGFloat { screen.minY + page / 344 * screen.height }

        /// A half's face, each as seen flat with its crease side where it is open: the inner display's left half (the
        /// cover's front) or right half, or the outer display (the cover's back, its spine on the left, as closed).
        enum Face {
            case left, right, outer

            var screen: CGRect {
                let p = Fold.panel, b = Fold.bezel
                return switch self {
                case .left: CGRect(x: b, y: b, width: p.width - b, height: p.height - 2 * b)
                case .right: CGRect(x: 0, y: b, width: p.width - b, height: p.height - 2 * b)
                case .outer: CGRect(x: Fold.spine, y: b, width: p.width - Fold.spine - b, height: p.height - 2 * b)
                }
            }

            /// Rounded on the free side, `spine` on the crease's.
            func radii(_ corner: CGFloat, spine: CGFloat) -> RectangleCornerRadii {
                self == .left
                    ? RectangleCornerRadii(topLeading: corner, bottomLeading: corner, bottomTrailing: spine, topTrailing: spine)
                    : RectangleCornerRadii(topLeading: spine, bottomLeading: spine, bottomTrailing: corner, topTrailing: corner)
            }

            /// The glow's centre, at the top of the whole screen: open, the crease.
            var glow: UnitPoint {
                switch self {
                case .left: UnitPoint(x: 1, y: 0.08)
                case .right: UnitPoint(x: 0, y: 0.08)
                case .outer: UnitPoint(x: 0.5, y: 0.08)
                }
            }

            /// The text's margins in the screen: a gutter at the crease; the outer display's text as far from the edge
            /// as the iPhone's.
            var margins: (leading: CGFloat, trailing: CGFloat) {
                switch self {
                case .left: (22, 18)
                case .right: (18, 22)
                case .outer: (29, 22)
                }
            }

            /// Its five lines, each a share of the text's width. Open, the page is a spread, a date on each side, lit in
            /// the order the closed screen lights its two.
            var lines: [CGFloat] {
                switch self {
                case .left: [0.94, 0.6, 0.8, 0.66, 0.5]
                case .right: [0.78, 0.92, 0.62, 0.5, 0.86]
                case .outer: OnboardingStage.screenLines
                }
            }

            /// Which of the two date chips is on line `k`, if one is.
            func chip(_ k: Int) -> Int? {
                switch self {
                case .left: k == 1 ? 0 : nil
                case .right: k == 3 ? 1 : nil
                case .outer: k == 1 ? 0 : k == 3 ? 1 : nil
                }
            }
        }
    }

    /// Calls its content with the opening as drawn this frame, so a change of the hinge, animated, swings the device
    /// (and the way to the cloud with it) rather than jumping it.
    private struct Folding<Content: View>: View, @MainActor Animatable {
        var opening: Double
        @ViewBuilder let content: (Double) -> Content
        var animatableData: Double {
            get { opening }
            set { opening = newValue }
        }
        var body: some View { content(opening) }
    }

    /// The hinge, where the device has one (iPhone Duo, iOS 27.1): its opening each time it moves, 0 closed to 1 open
    /// flat, from its status where it is shut or fully open and from its angle between; nil where there is none. It is
    /// read as the view appears, too. `--hinge <degrees>` (DEBUG) has any device read as iPhone Duo held that far open
    /// (0 shut, 180 flat), and `--hinge sweep` opens and shuts it over and over, a reading every frame or so.
    private struct FollowsHinge: ViewModifier {
        let changed: @MainActor (Double?) -> Void

        func body(content: Content) -> some View {
            #if DEBUG
            if let pretend = MainTabs.debugValue("--hinge") {
                content.task { await Self.pretend(pretend, changed) }
            } else {
                reading(content)
            }
            #else
            reading(content)
            #endif
        }

        @ViewBuilder private func reading(_ content: Content) -> some View {
            if #available(iOS 27.1, *) {
                content.onHingeChange { _, now in changed(now.hinge.map(Self.opening)) }
            } else {
                content
            }
        }

        @available(iOS 27.1, *)
        private static func opening(_ hinge: DeviceHinge) -> Double {
            switch hinge.status {
            case .closed: 0
            case .fullyOpen: 1
            default: opening(degrees: hinge.angle.degrees)
            }
        }

        private static func opening(degrees: Double) -> Double { min(max(degrees / 180, 0.01), 0.99) }

        #if DEBUG
        private static func pretend(_ value: String, _ changed: @MainActor (Double?) -> Void) async {
            func read(_ degrees: Double) { changed(degrees <= 0 ? 0 : degrees >= 180 ? 1 : opening(degrees: degrees)) }
            guard value == "sweep" else {
                if let degrees = Double(value) { read(degrees) }
                return
            }
            while !Task.isCancelled {
                // Shut for a second, opened over three, open for a second, shut again over three.
                for step in 0..<240 {
                    let t = Double(step) / 30
                    read(t < 1 ? 0 : t < 4 ? (1 - cos((t - 1) / 3 * .pi)) * 90 : t < 5 ? 180 : (1 + cos((t - 5) / 3 * .pi)) * 90)
                    try? await Task.sleep(for: .milliseconds(33))
                    if Task.isCancelled { return }
                }
            }
        }
        #endif
    }
}

/// A date thrown from its line onto its day: along a curve, up a little and then down. Or, given `via`, along that
/// curve (a page up to the cloud).
private struct Along: ViewModifier, @MainActor Animatable {   // a view modifier is the main actor's, and so is its conformance
    var progress: CGFloat
    let from: CGPoint, to: CGPoint
    var via: CGPoint?
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    func body(content: Content) -> some View {
        let control = via ?? CGPoint(x: to.x, y: from.y - abs(to.y - from.y) * 0.18)
        let t = progress, u = 1 - progress
        return content.position(x: u * u * from.x + 2 * u * t * control.x + t * t * to.x,
                                y: u * u * from.y + 2 * u * t * control.y + t * t * to.y)
    }
}

/// The way from the device up to the cloud, drawn as it is trimmed.
private struct Arc: Shape {
    let from: CGPoint, via: CGPoint, to: CGPoint
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: from)
        path.addQuadCurve(to: to, control: via)
        return path
    }
}

/// A cloud: a flat base and two bumps, one outline.
private struct Cloud: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let base = Path(roundedRect: CGRect(x: rect.minX, y: rect.minY + h * 0.42, width: w, height: h * 0.58), cornerRadius: h * 0.29)
        let left = Path(ellipseIn: CGRect(x: rect.minX + w * 0.1, y: rect.minY + h * 0.2, width: w * 0.38, height: w * 0.38))
        let right = Path(ellipseIn: CGRect(x: rect.minX + w * 0.36, y: rect.minY, width: w * 0.48, height: w * 0.48))
        return base.union(left).union(right)
    }
}

/// A check, drawn as it is trimmed.
private struct Check: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.28, y: rect.minY + rect.height * 0.52))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.44, y: rect.minY + rect.height * 0.68))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.73, y: rect.minY + rect.height * 0.36))
        return path
    }
}
#endif
