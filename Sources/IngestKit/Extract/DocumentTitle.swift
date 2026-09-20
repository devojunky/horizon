import Foundation
import FoundationModels

/// What to tell the device model about a document it is asked to name.
public struct DocumentTitleRequest: Sendable, Equatable {
    /// The user's name for the file (the stored copy is named by its hash).
    public var filename: String
    /// The course the document is filed under, when the user has said.
    public var course: String?
    public init(filename: String, course: String? = nil) { self.filename = filename; self.course = course }
}

/// How asking for a title went.
public enum DocumentTitleOutcome: Sendable, Equatable {
    case titled(String)
    /// The model was asked and had nothing worth keeping (it declined, or named what the document never says): not asked again.
    case nothing
    /// The device model is not there to ask (no Apple Intelligence, assets loading, held back in the background): ask another time.
    case unavailable
}

/// What the app calls a document. A title is the device model's ("Calculus II Syllabus"); without one, the file's name
/// without the clutter. Naming is a small task with nothing at stake, so it is the device model's whatever reads the
/// document, and a title is only kept when the document's own words carry it.
public enum DocumentName {
    public static func display(title: String?, filename: String) -> String {
        if let title, !title.isEmpty { return title }
        return tidy(filename)
    }

    /// "MA-UY_1124_syllabus_F26.pdf" → "MA-UY 1124 syllabus F26": no extension, no underscores; hyphens become spaces
    /// only when they are the file's only separators.
    public static func tidy(_ filename: String) -> String {
        var name = filename.removingPercentEncoding ?? filename
        let ext = (name as NSString).pathExtension
        if !ext.isEmpty, ext.count <= 5, ext.allSatisfy({ $0.isLetter || $0.isNumber }) { name = (name as NSString).deletingPathExtension }
        name = name.replacingOccurrences(of: "_", with: " ")
        if !name.contains(" ") { name = name.replacingOccurrences(of: "-", with: " ") }
        let tidy = Normalize.collapseWhitespace(name)
        return tidy.isEmpty ? filename : tidy
    }

    /// Words a title uses for the kind of document; they need no support from the document's text.
    static let kindWords: Set<String> = ["syllabus", "schedule", "course", "calendar", "assignment", "assignments", "list", "lab", "labs", "manual", "exam", "exams",
                                         "information", "info", "outline", "homework", "guide", "notes", "overview", "policy", "policies", "class", "and", "the", "for", "of"]

    /// The model's title, cleaned, or nil when it is not one: empty, a sentence, a file name, or a course the document
    /// and the file's name never mention (every word of its own must be theirs, whole or as the start of one).
    static func accept(_ raw: String, source: String, filename: String) -> String? {
        var title = Normalize.collapseWhitespace(raw).trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’.,:;·-– ").union(.whitespacesAndNewlines))
        for ext in [".pdf", ".docx", ".png", ".jpg", ".jpeg", ".heic", ".txt"] where title.lowercased().hasSuffix(ext) { title = String(title.dropLast(ext.count)) }
        let words = title.split(separator: " ")
        guard !title.isEmpty, title.count <= 60, (1...8).contains(words.count) else { return nil }
        let own = Normalize.key(title).split(separator: " ").map(String.init).filter { ($0.count >= 3 || $0.contains(where: \.isNumber)) && !kindWords.contains($0) }
        guard !own.isEmpty else { return title }   // "Course Syllabus": plain, but true of whatever it names
        let haystack = " " + Normalize.key(source + " " + filename) + " "
        return own.allSatisfy { haystack.contains(" \($0)") } ? title : nil   // a word, or the start of one ("Intro" for "Introduction")
    }

    /// The document's first words, enough to tell what it is: about a page of text, blank runs collapsed.
    static func opening(of document: NormalizedDocument, limit: Int = 1500) -> String {
        let text = document.textPages.prefix(2).map(\.text).joined(separator: "\n")
        let lines = text.split(whereSeparator: \.isNewline).map { Normalize.collapseWhitespace(String($0)) }.filter { !$0.isEmpty }
        return String(lines.joined(separator: "\n").prefix(limit))
    }

    /// For a picture the device model did not see: what was read from it, in a few lines.
    static func digest(of outcomes: [ExtractionOutcome], limit: Int = 1500) -> String {
        let transcripts = outcomes.compactMap(\.transcript).joined(separator: "\n")
        if !transcripts.isEmpty { return String(transcripts.prefix(limit)) }
        var lines: [String] = []
        if let course = outcomes.lazy.compactMap(\.extraction.course).first {
            lines.append([course.code, course.title].compactMap { $0 }.joined(separator: " "))
            if let term = course.term { lines.append(term) }
        }
        let platforms = Set(outcomes.flatMap { $0.extraction.obligations.map(\.platform) }).subtracting(["not_stated"])
        if !platforms.isEmpty { lines.append("Site: " + platforms.sorted().joined(separator: ", ")) }
        let items = outcomes.flatMap { $0.extraction.obligations.map { "\($0.title), \($0.dateAsWritten)" } }
        if !items.isEmpty { lines.append("Items: " + items.prefix(12).joined(separator: "; ")) }
        return String(lines.filter { !$0.isEmpty }.joined(separator: "\n").prefix(limit))
    }
}

@Generable
struct DocumentTitleDraft {
    @Guide(description: "The title: the course's name (or its code), then the kind of document. Three to six words.")
    var title: String
}

enum TitleInstructions {
    static let text = """
    You name university course documents for a student's list of files. From the file's name and the document's first lines, \
    write the title the student would know it by: the course, then the kind of document.
    The course is its name as the document prints it, such as Calculus II. Use its code, such as MA-UY 1124, only when the document gives no name; never both, and never a section number.
    The kind is a plain word or two for what the document is: Syllabus, Schedule, Assignment List, Lab Schedule, Lab Manual, Exam Information, Announcement, Reading List. \
    A document that gives a course's grading, policies and dates is a Syllabus, whatever its first heading says.
    Three to six words, in title case. No term, no dates, no file extension, no quotation marks.
    Examples: Calculus II Syllabus. Organic Chemistry I Lab Schedule. CS-UY 1134 Assignment List.
    """

    static func prompt(_ request: DocumentTitleRequest, text: String) -> String {
        var lines = ["File name: \(request.filename)"]
        if let course = request.course, !course.isEmpty { lines.append("Course it is filed under: \(course)") }
        lines.append("The document begins:\n\n\(text)")
        return lines.joined(separator: "\n")
    }
}

extension Extractor {
    /// The document's name for the user, asked of the device model whatever reads the document: a few hundred tokens
    /// in, a few words out, nothing at stake. The title is kept only when the document's words carry it (`DocumentName.accept`).
    static func title(from text: String, request: DocumentTitleRequest, log: @escaping @Sendable (String) -> Void) async -> DocumentTitleOutcome {
        guard !text.isEmpty else { return .nothing }
        let model = SystemLanguageModel.default
        guard case .available = model.availability else { return .unavailable }
        let start = ContinuousClock.now
        do {
            let session = LanguageModelSession(model: model, instructions: Instructions(TitleInstructions.text))
            let response = try await session.respond(to: Prompt(TitleInstructions.prompt(request, text: text)), generating: DocumentTitleDraft.self,
                                                     options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 48))
            let usage = response.usage
            let record = UsageRecord(step: "title", chunk: 0, route: .onDevice, inputTokens: usage.input.totalTokenCount, cachedTokens: usage.input.cachedTokenCount,
                                     outputTokens: usage.output.totalTokenCount, durationMs: Int((ContinuousClock.now - start) / .milliseconds(1)))
            let raw = response.content.title
            guard let title = DocumentName.accept(raw, source: text, filename: request.filename) else {
                log("title (onDevice): in \(record.inputTokens) out \(record.outputTokens) \(record.durationMs)ms, set aside: “\(raw)”")
                return .nothing
            }
            log("title (onDevice): in \(record.inputTokens) out \(record.outputTokens) \(record.durationMs)ms, “\(title)”")
            return .titled(title)
        } catch is CancellationError {
            return .unavailable
        } catch LanguageModelError.rateLimited {
            return .unavailable   // the device model holds back an app in the background: another time
        } catch {
            log("title: the device model \(Self.isSafetyStop(error) ? "declined" : "failed"): \(error.localizedDescription)")
            return .nothing
        }
    }
}
