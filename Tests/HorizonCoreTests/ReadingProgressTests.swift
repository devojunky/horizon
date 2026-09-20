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
        #expect(ReadingProgress.caption(ReadProgress(stage: .sizing)) == "Sizing it up…")
        #expect(ReadingProgress.caption(ReadProgress(stage: .sizing, outline: Self.outline)) == "Measured: 4 due")
        #expect(ReadingProgress.caption(ReadProgress(stage: .sizing, done: 7)) == "Sizing it up · 7 due so far")
        #expect(ReadingProgress.caption(ReadProgress(stage: .obligations, done: 2, total: 4, current: "Quiz 1")) == "What's due · 3 of 4 · Quiz 1")   // the third is under way
        #expect(ReadingProgress.caption(ReadProgress(stage: .obligations, done: 4, total: 4)) == "What's due · 4 of 4")
        #expect(ReadingProgress.caption(ReadProgress(stage: .obligations, done: 2)) == "What's due · 2 so far")
        #expect(ReadingProgress.caption(ReadProgress(stage: .policies, done: 2, total: 2)) == "The fine print · 2 of 2")
        #expect(ReadingProgress.caption(ReadProgress(stage: .grading)) == "How it's graded")
        #expect(ReadingProgress.caption(ReadProgress(stage: .transcribing)) == "Reading the picture…")
    }

    /// The line never wraps: every stage's widest wording is short when nothing in it is the document's own, and
    /// each wording after it is shorter, down to the count alone.
    @Test func everyWordingIsShortAndTheLadderOnlyNarrows() {
        let long = "Problem Set 10: Sequences, Series and Convergence Tests"
        let cases = ReadProgress.Stage.allCases.flatMap { stage in
            [ReadProgress(stage: stage), ReadProgress(stage: stage, done: 12), ReadProgress(stage: stage, done: 12, total: 18, current: long, outline: Self.outline)]
        }
        for progress in cases {
            let wordings = ReadingProgress.captions(progress)
            #expect(!wordings.isEmpty)
            #expect(wordings.map(\.count) == wordings.map(\.count).sorted(by: >), "\(wordings)")
            #expect(wordings.filter { !$0.contains(long) }.allSatisfy { $0.count <= 28 }, "\(wordings)")   // only an item's name can make a wording long
            #expect(wordings[wordings.count - 1].count <= 18, "\(wordings)")                               // and the last resort fits anywhere
        }
    }

    @Test func aReadInPartsSaysWhichAndDropsItLast() {
        let items = ReadProgress(stage: .obligations, done: 7, total: 18, current: "Quiz 8")
        #expect(ReadingProgress.lines(items, part: 1, of: 1) == ["What's due · 8 of 18 · Quiz 8", "What's due · 8 of 18", "8 of 18 due"])
        #expect(ReadingProgress.lines(items, part: 2, of: 3) == ["Part 2 of 3 · What's due · 8 of 18 · Quiz 8", "Part 2 of 3 · What's due · 8 of 18", "Part 2 of 3 · 8 of 18 due", "8 of 18 due"])
        let resumed = ReadingProgress.lines(nil, part: 2, of: 3, pickedUp: true, found: 5)
        #expect(resumed == ["Resumed at part 2 of 3 · 5 found so far", "Part 2 of 3 · 5 found so far", "5 found so far"])
        #expect(ReadingProgress.lines(nil, part: 1, of: 1, found: 0) == ["0 found so far"])
    }
}
