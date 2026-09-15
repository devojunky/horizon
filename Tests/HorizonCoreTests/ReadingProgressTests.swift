import Testing
import Foundation
import IngestKit
@testable import HorizonCore

struct ReadingProgressTests {
    static let outline = ReadProgress.Outline(titles: ["HW 1", "HW 2", "Quiz 1", "Midterm"], gradeRows: 3, policies: 2, breaks: 1)

    @Test func aListStageFillsItsBandItemByItem() {
        let items = ReadProgress(stage: .obligations, done: 2, total: 4, current: "Quiz 1", outline: Self.outline)
        #expect(abs(ReadingProgress.fraction(items) - (0.32 + 0.53 * 0.5)) < 1e-9)
        #expect(abs(ReadingProgress.mark(items) - (0.32 + 0.53 * 0.75)) < 1e-9)                     // creeps toward the next item's share
        #expect(abs(ReadingProgress.fraction(ReadProgress(stage: .obligations, done: 4, total: 4)) - 0.85) < 1e-9)
        #expect(abs(ReadingProgress.fraction(ReadProgress(stage: .breaks, done: 1, total: 1)) - 0.96) < 1e-9)   // the merge keeps the last
    }

    @Test func withoutATotalTheBandOnlyStarts() {
        let device = ReadProgress(stage: .obligations, done: 5)
        #expect(ReadingProgress.fraction(device) == 0.32 && ReadingProgress.mark(device) == 0.85)
        #expect(ReadingProgress.fraction(ReadProgress(stage: .sizing)) == 0 && ReadingProgress.fraction(ReadProgress(stage: .course)) == 0.20)
    }

    @Test func theStagesNeverGoBackwards() {
        let order: [ReadProgress.Stage] = [.sizing, .course, .grading, .obligations, .policies, .breaks]
        let starts = order.map { ReadingProgress.band($0).lowerBound }
        #expect(starts == starts.sorted() && ReadingProgress.band(.transcribing).upperBound <= ReadingProgress.band(.course).upperBound)
    }

    @Test func theCaptionNamesTheStageAndTheCount() {
        #expect(ReadingProgress.caption(ReadProgress(stage: .sizing)) == "Taking the measure of it…")
        #expect(ReadingProgress.caption(ReadProgress(stage: .sizing, outline: Self.outline)) == "Measured: 4 things due")
        #expect(ReadingProgress.caption(ReadProgress(stage: .sizing, done: 7)) == "Taking the measure of it · 7 due so far")
        #expect(ReadingProgress.caption(ReadProgress(stage: .obligations, done: 2, total: 4, current: "Quiz 1")) == "What's due · Quiz 1 · 2 of 4")
        #expect(ReadingProgress.caption(ReadProgress(stage: .obligations, done: 2)) == "What's due · 2 so far")
        #expect(ReadingProgress.caption(ReadProgress(stage: .policies, done: 2, total: 2)) == "The fine print · 2 of 2")
        #expect(ReadingProgress.caption(ReadProgress(stage: .grading)) == "How the grade adds up")
        #expect(ReadingProgress.caption(ReadProgress(stage: .transcribing)) == "Reading the picture, line by line…")
    }
}
