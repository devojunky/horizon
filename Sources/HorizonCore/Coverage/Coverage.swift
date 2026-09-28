import Foundation
import IngestKit

/// Where the app is probably blind for one course (SPEC §6.1). Not a task list: the signals that say
/// "something is due that nobody told you about".
public struct CourseCoverage: Sendable, Identifiable, Equatable {
    public var id: UUID { course.id }
    public var course: CourseSnapshot
    /// Days since the user last completed one of the course's items (checked off in the app or in Reminders), or, when
    /// nothing has been completed since, since the course came into the app. A check resets it to 0; unchecking gives
    /// back the completion before. Reading a document leaves it alone: that is `daysSinceUpdate`.
    public var daysSilent: Int?
    /// The silence is worth saying (the accent, the headline, the suspicion): a week or more of it, with work that fell
    /// due during it still open. A course with nothing due is quiet, not silent.
    public var isSilent: Bool
    /// Days since a document for the course was last read ("Updated 7 days ago"). Nil when none ever was.
    public var daysSinceUpdate: Int?
    /// Obligations due in the next 14 days, not completed.
    public var upcoming14: Int
    public var cadenceGaps: [CadenceGap]
    /// Sites the course's documents say its work lives on, from which nothing has ever been read.
    public var neverIngested: [PlatformGap]
    /// No document was ever read for the course and it has no items.
    public var nothingOnFile: Bool
    /// Higher is worse. Courses sort by this, never by name.
    public var suspicion: Double
    /// "Bio has been silent for 9 days and its syllabus implies weekly quizzes." The whole story in one sentence: what
    /// VoiceOver reads for the course. The page shows it as `findings` and `facts`.
    public var headline: String

    public var displayName: String { course.displayName }

    /// How fresh the course's documents are, in a few words: "Updated today", "Updated 7 days ago"; nil when no document
    /// was ever read for it.
    public var updatedLine: String? {
        daysSinceUpdate.map { $0 == 0 ? "Updated today" : $0 == 1 ? "Updated yesterday" : "Updated \($0) days ago" }
    }

    /// What says the app may be blind here, strongest first, one short line each: the silence, an empty course, the
    /// rhythms the syllabus sets that the items on file do not keep, the sites never read. Empty when nothing does. A
    /// site's grade rows are named only when no line before it names them all: a long row is not said twice.
    public var findings: [String] {
        var lines: [String] = []
        if isSilent, let days = daysSilent { lines.append("Silent for \(days) days while work fell due.") }
        if nothingOnFile { lines.append("Nothing on file.") }
        lines += cadenceGaps.map(\.finding)
        let named = Set(cadenceGaps.map { Normalize.key($0.component) })
        lines += neverIngested.map { $0.finding(listing: !$0.components.allSatisfy { named.contains(Normalize.key($0)) }) }
        return lines
    }

    /// The course's figures, a few words each: what is due in the next two weeks, the days since the last check (unless
    /// a finding says it), how fresh the documents are.
    public var facts: [String] {
        var parts = [upcoming14 == 0 ? "Nothing due in the next two weeks" : "\(upcoming14) due in the next two weeks"]
        if let daysSilent, !isSilent { parts.append(daysSilent == 1 ? "1 day silent" : "\(daysSilent) days silent") }
        if let updatedLine { parts.append(updatedLine) }
        return parts
    }
}

/// A grade component whose stated rhythm is not showing up in the obligations on file.
public struct CadenceGap: Sendable, Equatable {
    public var component: String
    public var cadence: Cadence?
    /// Items the rhythm implies for the next 14 days, and how many are actually on file for that window.
    public var expectedInWindow: Int
    public var onFileInWindow: Int
    /// Items on file for the whole term versus what the syllabus states or implies.
    public var onFileTotal: Int
    public var expectedTotal: Int?

    public var sentence: String {
        let rhythm: String = switch cadence { case .weekly: "weekly"; case .biweekly: "biweekly"; default: "\(expectedTotal ?? 0)" }
        var noun = component.lowercased()
        if cadence != nil, noun.hasPrefix(rhythm + " ") { noun = String(noun.dropFirst(rhythm.count + 1)) }   // "Weekly Quizzes": not "weekly weekly quizzes"
        if cadence != nil {
            return onFileInWindow == 0 ? "syllabus implies \(rhythm) \(noun); none on file for the next two weeks"
                                       : "syllabus implies \(rhythm) \(noun); only \(onFileInWindow) of \(expectedInWindow) on file for the next two weeks"
        }
        return "syllabus lists \(expectedTotal ?? 0) \(noun); \(onFileTotal) on file"
    }

    /// "Homework (weekly): none on file for the next two weeks." The grade row leads, named as the syllabus prints it,
    /// with its rhythm unless the name carries it ("Weekly Quizzes").
    public var finding: String {
        guard let cadence, cadence != .once else { return "\(component): \(onFileTotal) of \(expectedTotal ?? 0) on file." }
        let rhythm = cadence == .weekly ? "weekly" : "biweekly"
        let label = component.lowercased().split(whereSeparator: { !$0.isLetter }).contains(Substring(rhythm)) ? component : "\(component) (\(rhythm))"
        return onFileInWindow == 0 ? "\(label): none on file for the next two weeks." : "\(label): \(onFileInWindow) of \(expectedInWindow) on file for the next two weeks."
    }
}

/// A site the documents say some of the course's work lives on ("Homework (WebAssign)"), from which no page has ever
/// been read: the app knows the syllabus's schedule, not the site's own.
public struct PlatformGap: Sendable, Equatable {
    public var platform: Platform
    /// The grade components on it, as the documents name them; empty when only items name it.
    public var components: [String]

    /// "its homework is on WebAssign, from which nothing has ever been read"; `first` when it opens the sentence.
    public func sentence(name: String, first: Bool) -> String {
        let site = Coverage.platformName(platform)
        let owner = first ? "\(name)'s" : "its"
        let what: String
        switch components.count {
        case 0: what = "\(first ? name : "it") has items on \(site)"
        case 1: what = "\(owner) \(components[0].lowercased()) \(Self.plural(components[0]) ? "are" : "is") on \(site)"
        default: what = "\(owner) " + components.map { $0.lowercased() }.dropLast().joined(separator: ", ") + " and \(components.last!.lowercased()) are on \(site)"
        }
        return what + ", from which nothing has ever been read"
    }

    /// "WebAssign (Homework): nothing read yet." The site leads; `listing` names the grade rows on it.
    public func finding(listing: Bool) -> String {
        let site = Coverage.platformName(platform)
        return (listing && !components.isEmpty ? "\(site) (\(components.joined(separator: ", ")))" : site) + ": nothing read yet."
    }

    /// "Quizzes", "Lab Reports": plural; "Homework", "Final Paper": not.
    static func plural(_ component: String) -> Bool {
        guard let last = component.split(separator: " ").last?.lowercased() else { return false }
        return last.hasSuffix("s") && !last.hasSuffix("ss")
    }
}

public enum Coverage {
    public static let window: TimeInterval = 14 * 86400
    /// Days without a completion, with work falling due meanwhile, before a course is called silent.
    public static let silentAfter = 7
    /// File kinds that are pictures of a site rather than documents about the course.
    static let imageKinds: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "webp", "gif"]

    public static func assess(course: CourseSnapshot, obligations: [ObligationSnapshot], documents: [DocumentSnapshot], now: Date = Date(), calendar: Calendar = .current) -> CourseCoverage {
        let mine = obligations.filter { $0.courseID == course.id && $0.deletedAt == nil }
        let docs = documents.filter { $0.courseID == course.id && $0.status == .parsed }
        func days(since date: Date) -> Int { max(0, calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0) }
        // Silence is the user's: the last item completed, or the course's arrival when nothing has been completed since.
        let quietSince = ([course.createdAt] + mine.map(\.completedAt)).compactMap { $0 }.max()
        let daysSilent = quietSince.map(days(since:))
        let fellDue = quietSince.map { start in mine.contains { $0.completedAt == nil && ($0.due.map { $0 > start && $0 <= now } ?? false) } } ?? false
        let isSilent = fellDue && (daysSilent ?? 0) >= silentAfter
        // Freshness is the documents': the last one read for the course.
        let lastRead = ([course.lastIngested] + docs.map(\.ingestedAt)).compactMap { $0 }.max()
        let daysSinceUpdate = lastRead.map(days(since:))
        let nothingOnFile = lastRead == nil && mine.isEmpty
        // "The next two weeks" runs through the end of the 14th day from today, so a date-only deadline (23:59) on that day counts.
        let today = calendar.startOfDay(for: now)
        let windowEnd = calendar.date(byAdding: .day, value: 15, to: today) ?? now.addingTimeInterval(window)
        let inWindow = mine.filter { $0.completedAt == nil && ($0.due.map { $0 >= now && $0 < windowEnd } ?? false) }
        // Rhythm is only expected while the term runs: count the days of the window that fall inside it.
        let termOpen = course.termStart.map { max(today, calendar.startOfDay(for: $0)) } ?? today
        let termClose = course.termEnd.flatMap { calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: $0)) }.map { min(windowEnd, $0) } ?? windowEnd
        let termDays = max(0, calendar.dateComponents([.day], from: termOpen, to: termClose).day ?? 0)

        var gaps: [CadenceGap] = []
        for component in course.gradeComponents {
            let key = Normalize.key(component.name)
            let onFile = mine.filter { $0.componentName.map(Normalize.key) == key }
            let onFileInWindow = inWindow.filter { $0.componentName.map(Normalize.key) == key }.count
            let termOver = course.termEnd.map { $0 < now } ?? false
            if let cadence = component.cadence, cadence != .once, !termOver {
                let expectedInWindow = cadence == .weekly ? termDays / 7 : termDays / 14
                if expectedInWindow > 0, onFileInWindow < expectedInWindow {
                    gaps.append(CadenceGap(component: component.name, cadence: cadence, expectedInWindow: expectedInWindow, onFileInWindow: onFileInWindow,
                                           onFileTotal: onFile.count, expectedTotal: component.expectedCount))
                }
            } else if let expected = component.expectedCount, expected > 1, onFile.count < expected / 2 {
                gaps.append(CadenceGap(component: component.name, cadence: nil, expectedInWindow: 0, onFileInWindow: onFileInWindow, onFileTotal: onFile.count, expectedTotal: expected))
            }
        }

        // Sites the documents say the work lives on: the grading rows (component platforms) and the live items' own
        // rows. The course's record of sites ever seen is not used: an item corrected by hand or deleted no longer
        // stands for one, and neither does a guess that was never the document's word.
        var componentsOn: [Platform: [String]] = [:]
        var named = Set<Platform>()
        for component in course.gradeComponents {
            guard let p = component.platform, p != .syllabusOnly else { continue }
            named.insert(p)
            if !componentsOn[p, default: []].contains(component.name) { componentsOn[p, default: []].append(component.name) }
        }
        for item in mine where item.platform != .syllabusOnly {
            named.insert(item.platform)
            if let c = item.componentName, !componentsOn[item.platform, default: []].contains(where: { Normalize.key($0) == Normalize.key(c) }) { componentsOn[item.platform, default: []].append(c) }
        }
        // A page of the site has been read when a screenshot names it, or when an item came from a picture at all: a
        // WebAssign page rarely spells its own name where Vision can read it.
        var ingestedFrom = Set(docs.compactMap(\.platform))
        let pictures = Set(docs.filter { imageKinds.contains($0.kind.lowercased()) }.map(\.id))
        for item in mine where item.sourceDocumentID.map(pictures.contains) == true { ingestedFrom.insert(item.platform) }
        let never = Platform.allCases.filter { named.contains($0) && !ingestedFrom.contains($0) }.map { PlatformGap(platform: $0, components: componentsOn[$0] ?? []) }

        var suspicion = 0.0
        if isSilent, let days = daysSilent { suspicion += min(Double(days), 30) * 0.05 }
        if nothingOnFile { suspicion += 1 }
        suspicion += Double(gaps.count) * 0.4
        suspicion += Double(never.count) * 0.3
        if inWindow.isEmpty, !course.gradeComponents.isEmpty { suspicion += 0.3 }

        return CourseCoverage(course: course, daysSilent: daysSilent, isSilent: isSilent, daysSinceUpdate: daysSinceUpdate, upcoming14: inWindow.count,
                              cadenceGaps: gaps, neverIngested: never, nothingOnFile: nothingOnFile, suspicion: suspicion,
                              headline: headline(course: course, silentFor: isSilent ? daysSilent : nil, nothingOnFile: nothingOnFile, upcoming: inWindow.count, gaps: gaps, never: never))
    }

    /// One sentence a person would say. The strongest signals only, each clause carrying its own subject.
    static func headline(course: CourseSnapshot, silentFor: Int?, nothingOnFile: Bool, upcoming: Int, gaps: [CadenceGap], never: [PlatformGap]) -> String {
        let name = course.displayName
        var clauses: [String] = []
        if let days = silentFor { clauses.append("\(name) has been silent for \(days) days") }
        if nothingOnFile { clauses.append("\(name) has nothing on file") }
        if let gap = gaps.first { clauses.append((clauses.isEmpty ? "\(name)'s " : "its ") + gap.sentence) }
        if let gap = never.first { clauses.append(gap.sentence(name: name, first: clauses.isEmpty)) }
        guard !clauses.isEmpty else {
            return upcoming == 0 ? "\(name) has nothing due in the next two weeks." : "\(name) looks covered: \(upcoming) due in the next two weeks."
        }
        let joined = clauses.count == 1 ? clauses[0] : clauses.dropLast().joined(separator: ", ") + " and " + clauses.last!
        return joined.prefix(1).uppercased() + joined.dropFirst() + "."
    }

    public static func platformName(_ p: Platform) -> String {
        switch p { case .lms: "LMS"; case .webAssign: "WebAssign"; case .gradescope: "Gradescope"; case .myLab: "MyLab"; case .syllabusOnly: "syllabus" }
    }
}
