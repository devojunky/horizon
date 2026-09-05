import Testing
import FoundationModels
@testable import IngestKit

/// A page of policies can exhaust the output budget mid-response; what has fully streamed must survive.
struct SalvageTests {
    static func partial(_ json: String) throws -> ChunkExtraction.PartiallyGenerated {
        try ChunkExtraction.PartiallyGenerated(GeneratedContent(json: json))
    }

    @Test func keepsCompleteItemsAndDropsTheCutOffOne() throws {
        let cut = try Self.partial("""
        {"course": {"code": "MA-UY 1124", "title": "Calculus II", "term": "Fall 2026", "meetings": []},
         "gradeComponents": [{"name": "Homework", "weightPercent": 15, "cadence": "weekly", "platform": "webassign"}, {"name": "Quizzes"}],
         "obligations": [{"title": "HW 1", "platform": "webassign", "dateAsWritten": "Wed 9/9", "dueDate": "2026-09-09", "confidence": "high"},
                         {"title": "HW 2", "platform": "webassign", "dateAsWritten": "9/16", "dueDate": "2026-09-16", "confidence": "high"},
                         {"title": "Quiz 1", "platform": "not_stated", "dateAsWritten": "Thu 9/1"}],
         "policies": [{"kind": "late_work", "text": "Late homework is not accepted."}, {"kind": "attendance", "text": "Attendance in recita"}]}
        """)
        let salvaged = try #require(Extractor.salvage(cut))
        #expect(salvaged.obligations.map(\.title) == ["HW 1", "HW 2"])          // Quiz 1 was mid-stream
        #expect(salvaged.gradeComponents.map(\.name) == ["Homework"])           // "Quizzes" had no cadence/platform yet
        #expect(salvaged.policies.map(\.kind) == ["late_work"])
        #expect(salvaged.course?.code == "MA-UY 1124" && salvaged.course?.term == "Fall 2026")
    }

    @Test func nothingCompleteMeansNothingSalvaged() throws {
        let barely = try Self.partial("""
        {"obligations": [{"title": "HW 1", "platform": "webassign"}]}
        """)
        #expect(Extractor.salvage(barely) == nil)
    }

    @Test func provisionalRowsNeedOnlyATitle() throws {
        let partial = try Self.partial("""
        {"obligations": [{"title": "HW 1", "platform": "webassign", "dateAsWritten": "Wed 9/9"}, {"title": "Qu"}]}
        """)
        let rows = Extractor.provisional(partial, call: 2)
        #expect(rows.map(\.title) == ["HW 1", "Qu"] && rows[0].id == "2-0" && rows[0].dateAsWritten == "Wed 9/9" && rows[1].dateAsWritten == nil)
    }
}
