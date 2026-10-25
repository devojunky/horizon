#if os(iOS)
import SwiftUI
import HorizonCore

/// The first launch on a phone with nothing on file (DECISIONS 2026-10-25 · Onboarding): four short pages under one
/// stage where Horizon's icon comes alive. The horizon is drawn, the sun rises from behind it and the term's marks stand
/// up on it; then a syllabus is read onto that horizon, its deadlines go to Reminders, and a missing week is noticed.
/// Every mark lands with a tap as strong as its weight. Swipe or Continue, Skip on any page, a tap on the stage plays it
/// again. Nothing is asked for here: Reminders access waits until there is something to write.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.colorScheme) private var colorScheme
    let finish: () -> Void
    @State private var page: Int
    @State private var replay = 0
    @State private var leaving = false
    @State private var stageGone = false
    @State private var gone = false
    @State private var begun = 0

    init(startPage: Int = 0, finish: @escaping () -> Void) {
        _page = State(initialValue: min(max(startPage, 0), 3))
        self.finish = finish
    }

    private struct Page { let kicker: String, title: String, deck: String, aside: String? }

    private var pages: [Page] {
        let reads: String
        if model.usesReadingService {
            reads = "Claude reads it through Horizon's server, which keeps none of it, and every date is checked against the page itself."
        } else if model.readingRoute == .claude, !model.claudeKey.isEmpty {
            reads = "Claude reads it with your key, and every date is checked against the page itself."
        } else {
            reads = "It is read on this phone, so nothing leaves it, and every date is checked against the page itself."
        }
        return [
            Page(kicker: "Horizon", title: "The whole term, on one horizon.",
                 deck: "Horizon reads your course documents and keeps every deadline in view, weighed by what it is worth.", aside: nil),
            Page(kicker: "Reading", title: "Share a syllabus. Horizon reads it.",
                 deck: "A PDF, a schedule, a photo of a printed page. \(reads)", aside: "Who reads is yours to choose in Settings."),
            Page(kicker: "Reminders", title: "Every deadline, in Reminders.",
                 deck: "They go to a list called Horizon, so they still remind you if you never open the app. Check one off there and Horizon knows.", aside: nil),
            Page(kicker: "Coverage", title: "And it notices what is missing.",
                 deck: "A weekly quiz with none on file next week, a course gone quiet while work fell due: Coverage says so before it costs you.", aside: nil),
        ]
    }

    private var last: Int { pages.count - 1 }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("Skip") { close(begin: false) }
                        .foregroundStyle(.secondary)
                        .opacity(page < last ? 1 : 0)
                        .disabled(page >= last || leaving)
                        .reachable()
                }
                .frame(height: 44)
                .padding(.horizontal, Design.margin)

                OnboardingStage(scene: OnboardingScene(rawValue: page) ?? .term, replay: replay, leaving: leaving)
                    .opacity(stageGone ? 0 : 1)
                    .frame(maxWidth: 440)
                    .frame(height: stageHeight(in: proxy.size))
                    .padding(.horizontal, Design.margin)
                    .contentShape(Rectangle())
                    .onTapGesture { if !leaving { replay += 1 } }   // the scene again: a way to look at it, not a control to find
                    .accessibilityHidden(true)

                TabView(selection: $page) {
                    ForEach(pages.indices, id: \.self) { index in
                        PageText(kicker: pages[index].kicker, title: pages[index].title, deck: pages[index].deck, aside: pages[index].aside).tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .opacity(leaving ? 0 : 1)

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
                        // At night the tint is the bright orange, where white words read at about 1.9:1: dark ink there.
                        Text(page < last ? "Continue" : "Begin").font(.headline).frame(maxWidth: .infinity).frame(minHeight: 30)
                            .foregroundStyle(colorScheme == .dark ? Design.paper : .white)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: 440)
                    .disabled(leaving)
                }
                .padding(.horizontal, Design.margin)
                .padding(.bottom, 12)
                .opacity(leaving ? 0 : 1)
            }
            .frame(maxWidth: .infinity)
        }
        // The page's own paper goes last, once nothing is drawn on it, so the app comes in on the same paper: a fade
        // through, never the stage over the app at half strength.
        .background(Design.paper.opacity(gone ? 0 : 1).ignoresSafeArea())
        .tint(Design.accentInk)
        .sensoryFeedback(.selection, trigger: page)
        .sensoryFeedback(.success, trigger: begun)
    }

    /// The stage's height: its own proportion at the width it has, less on a short screen (landscape) and at the
    /// accessibility text sizes, where the words need the room.
    private func stageHeight(in size: CGSize) -> CGFloat {
        let width = min(size.width - 2 * Design.margin, 440)
        let natural = width * OnboardingStage.aspect
        let share: CGFloat = typeSize.isAccessibilitySize ? 0.24 : 0.36
        return max(120, min(natural, size.height * share))
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

/// One page's words, set like the app's pages: a kicker, the display serif, a deck, on the margin's line.
private struct PageText: View {
    let kicker: String, title: String, deck: String
    let aside: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Kicker(kicker, accent: true)
                Text(title).display().fixedSize(horizontal: false, vertical: true)
                Text(deck).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let aside { Text(aside).font(.footnote).foregroundStyle(.secondary).padding(.top, 2).fixedSize(horizontal: false, vertical: true) }
            }
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Design.margin)
            .padding(.top, 18)
            .accessibilityElement(children: .combine)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

/// The four scenes, one per page.
enum OnboardingScene: Int { case term, read, remind, notice }

/// The stage: the app's icon in its own coordinates (a 1024-point square: the sun at 512, 468 with a radius of 204,
/// the horizon a bar from 116 to 908 at 642, seven ink marks standing on it), seen through a window from 150 to 770 so
/// there is room above the horizon for a page, its reminders, a week. Each scene is a choreography of states, run in
/// order and cancelled by the next; with Reduce Motion each arrives whole, by a fade.
struct OnboardingStage: View {
    let scene: OnboardingScene
    let replay: Int
    let leaving: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let top: CGFloat = 150
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

    var body: some View {
        GeometryReader { proxy in
            let s = proxy.size.width / 1024
            ZStack(alignment: .topLeading) {
                sunView(s)
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
        .onChange(of: leaving) { _, now in
            guard now else { return }
            if reduceMotion { return }
            withAnimation(.easeInOut(duration: 0.7)) { lift = 1; sunDim = 1; iconLayer = 0; termLayer = 0; readLayer = 0; rowsLayer = 0; weekLayer = 0 }
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
                iconLayer = 0; readLayer = 0; rowsLayer = 0; weekLayer = 0
                if !sharesTerm { termLayer = 0 }
            }
            guard await pause(0.18) else { return }
        }
        quietly { gapPulse = false; glow = false }
        switch scene {
        case .term: await term(again: again)
        case .read: await read()
        case .remind: await remind()
        case .notice: await notice()
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

/// A date thrown from its line onto its day: along a curve, up a little and then down.
private struct Along: ViewModifier, @MainActor Animatable {   // a view modifier is the main actor's, and so is its conformance
    var progress: CGFloat
    let from: CGPoint, to: CGPoint
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    func body(content: Content) -> some View {
        let control = CGPoint(x: to.x, y: from.y - abs(to.y - from.y) * 0.18)
        let t = progress, u = 1 - progress
        return content.position(x: u * u * from.x + 2 * u * t * control.x + t * t * to.x,
                                y: u * u * from.y + 2 * u * t * control.y + t * t * to.y)
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
