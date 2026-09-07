import Foundation
import IngestKit

/// Where the app is probably blind for one course (SPEC §6.1). Not a task list: the signals that say
/// "something is due that nobody told you about".
public struct CourseCoverage: Sendable, Identifiable, Equatable {
    public var id: UUID { course.id }
    public var course: CourseSnapshot
    /// Days since the last document for this course was read. Nil when nothing was ever ingested.
    public var daysSilent: Int?
    /// Obligations due in the next 14 days, not completed.
    public var upcoming14: Int
    public var cadenceGaps: [CadenceGap]
    /// Sites the course's documents say its work lives on, from which nothing has ever been read.
    public var neverIngested: [PlatformGap]
    /// Higher is worse. Courses sort by this, never by name.
    public var suspicion: Double
    /// "Bio has been silent for 9 days and its syllabus implies weekly quizzes."
    public var headline: String

    public var displayName: String { course.displayName }
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
        let noun = component.lowercased()
        if cadence != nil {
            return onFileInWindow == 0 ? "syllabus implies \(rhythm) \(noun); none on file for the next two weeks"
                                       : "syllabus implies \(rhythm) \(noun); only \(onFileInWindow) of \(expectedInWindow) on file for the next two weeks"
        }
        return "syllabus lists \(expectedTotal ?? 0) \(noun); \(onFileTotal) on file"
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

    /// "Quizzes", "Lab Reports": plural; "Homework", "Final Paper": not.
    static func plural(_ component: String) -> Bool {
        guard let last = component.split(separator: " ").last?.lowercased() else { return false }
        return last.hasSuffix("s") && !last.hasSuffix("ss")
    }
}

public enum Coverage {
    public static let window: TimeInterval = 14 * 86400
    /// File kinds that are pictures of a site rather than documents about the course.
    static let imageKinds: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "webp", "gif"]

    public static func assess(course: CourseSnapshot, obligations: [ObligationSnapshot], documents: [DocumentSnapshot], now: Date = Date(), calendar: Calendar = .current) -> CourseCoverage {
        let mine = obligations.filter { $0.courseID == course.id && $0.deletedAt == nil }
        let docs = documents.filter { $0.courseID == course.id && $0.status == .parsed }
        let lastRead = ([course.lastIngested] + docs.map(\.ingestedAt)).compactMap { $0 }.max()
        let daysSilent = lastRead.map { max(0, calendar.dateComponents([.day], from: calendar.startOfDay(for: $0), to: calendar.startOfDay(for: now)).day ?? 0) }
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
        if let days = daysSilent { suspicion += min(Double(days), 30) * 0.05 } else { suspicion += 1 }
        suspicion += Double(gaps.count) * 0.4
        suspicion += Double(never.count) * 0.3
        if inWindow.isEmpty, !course.gradeComponents.isEmpty { suspicion += 0.3 }

        return CourseCoverage(course: course, daysSilent: daysSilent, upcoming14: inWindow.count, cadenceGaps: gaps, neverIngested: never,
                              suspicion: suspicion, headline: headline(course: course, daysSilent: daysSilent, upcoming: inWindow.count, gaps: gaps, never: never))
    }

    /// One sentence a person would say. The strongest signals only, each clause carrying its own subject.
    static func headline(course: CourseSnapshot, daysSilent: Int?, upcoming: Int, gaps: [CadenceGap], never: [PlatformGap]) -> String {
        let name = course.displayName
        var clauses: [String] = []
        if let days = daysSilent, days >= 7 { clauses.append("\(name) has been silent for \(days) days") }
        if daysSilent == nil { clauses.append("\(name) has nothing on file") }
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
