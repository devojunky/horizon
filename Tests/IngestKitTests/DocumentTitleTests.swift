import Testing
import Foundation
@testable import IngestKit

/// A document's name for the user: the device model's title when the document's words carry it, else the file's name, tidied.
struct DocumentTitleTests {
    @Test func aFileNameLosesItsClutter() {
        #expect(DocumentName.tidy("MA-UY_1124_syllabus_F26.pdf") == "MA-UY 1124 syllabus F26")   // the code keeps its hyphen
        #expect(DocumentName.tidy("cs101-lab-schedule.docx") == "cs101 lab schedule")             // hyphens only when they are the separators
        #expect(DocumentName.tidy("Screenshot 2026-09-20 at 10.01.22.png") == "Screenshot 2026-09-20 at 10.01.22")
        #expect(DocumentName.tidy("Syllabus%20Fall.pdf") == "Syllabus Fall")
        #expect(DocumentName.tidy("notes.v2") == "notes")
        #expect(DocumentName.tidy("report.final-draft") == "report.final draft")                  // not an extension: only the hyphen goes
        #expect(DocumentName.tidy(".pdf") == ".pdf")
        #expect(DocumentName.display(title: "Calculus II Syllabus", filename: "x.pdf") == "Calculus II Syllabus")
        #expect(DocumentName.display(title: "", filename: "calc_syllabus.pdf") == "calc syllabus")   // asked, and the model had none
        #expect(DocumentName.display(title: nil, filename: "calc_syllabus.pdf") == "calc syllabus")
    }

    @Test func aTitleIsKeptOnlyWhenTheDocumentCarriesIt() {
        let source = "MA-UY 1124 Calculus II\nFall 2026 Syllabus\nInstructor: Dr. Rivera"
        #expect(DocumentName.accept("Calculus II Syllabus", source: source, filename: "s.pdf") == "Calculus II Syllabus")
        #expect(DocumentName.accept("  \"Calculus II Syllabus.\" ", source: source, filename: "s.pdf") == "Calculus II Syllabus")
        #expect(DocumentName.accept("Calculus II Syllabus.pdf", source: source, filename: "s.pdf") == "Calculus II Syllabus")
        #expect(DocumentName.accept("MA-UY 1124 Assignment List", source: source, filename: "s.pdf") == "MA-UY 1124 Assignment List")   // kind words need no support
        #expect(DocumentName.accept("Organic Chemistry Syllabus", source: source, filename: "s.pdf") == nil)                           // a course the document never names
        #expect(DocumentName.accept("Organic Chem Syllabus", source: "", filename: "organic_chemistry_syllabus.pdf") == "Organic Chem Syllabus")   // the file's name counts, and the start of a word is the word
        #expect(DocumentName.accept("Calculus III Syllabus", source: source, filename: "s.pdf") == nil)                                     // a numeral the document does not print
        #expect(DocumentName.accept("Course Syllabus", source: source, filename: "s.pdf") == "Course Syllabus")                          // plain, but true
        #expect(DocumentName.accept("", source: source, filename: "s.pdf") == nil)
        #expect(DocumentName.accept("This document is the syllabus for Calculus II, which covers integration techniques and series", source: source, filename: "s.pdf") == nil)   // a sentence
    }

    @Test func theOpeningIsAPageOfWordsAndAPictureHasNone() throws {
        let text = (1...200).map { "Line \($0) of the syllabus for Calculus II.   " }.joined(separator: "\n\n\n")
        let document = try DocumentNormalizer.normalize(text: text, name: "calc.txt")
        let opening = DocumentName.opening(of: document)
        #expect(opening.count <= 1500 && opening.hasPrefix("Line 1 of the syllabus for Calculus II.\nLine 2"))
    }

    @Test func aPictureIsNamedFromWhatWasReadOfIt() {
        let facts = ChunkExtraction(course: CourseFacts(code: "MA-UY 1124", title: "Calculus II", instructor: nil, term: "Fall 2026", termStart: nil, termEnd: nil, room: nil, meetings: []),
                                    gradeComponents: [], obligations: [ObligationFacts(title: "HW 3", platform: "webassign", component: nil, dateAsWritten: "Sep 23", dueDate: nil, confidence: "high")],
                                    policies: [], noClassDates: [])
        let usage = UsageRecord(step: "image", chunk: 0, route: .claude, inputTokens: 0, outputTokens: 0, durationMs: 0)
        let read = ExtractionOutcome(kind: .image, page: 0, extraction: facts, transcript: nil, usage: usage)
        let digest = DocumentName.digest(of: [read])
        #expect(digest == "MA-UY 1124 Calculus II\nFall 2026\nSite: webassign\nItems: HW 3, Sep 23")
        let transcribed = ExtractionOutcome(kind: .image, page: 0, extraction: facts, transcript: "WebAssign · My Assignments\nHW 3 due Sep 23", usage: usage)
        #expect(DocumentName.digest(of: [transcribed]) == "WebAssign · My Assignments\nHW 3 due Sep 23")   // Claude's transcript is the picture's own words
    }
}
