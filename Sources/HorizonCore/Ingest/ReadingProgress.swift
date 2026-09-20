import Foundation
import IngestKit

/// The reading bar's figure for one part, from where the model is in its reply. With Claude's outline the figure is
/// exact: each stage owns a band of the part, and a list stage fills its band item by item. Without an outline (the
/// device model) the figure falls back to the old count of streamed rows, and `ProgressCreep` does the rest.
public enum ReadingProgress {
    /// Where each stage's band ends, in 0...1 of the part. Sizing is the model reading the pages before its first
    /// word, a real share of the time; the obligations are most of the writing; the merge after the reply keeps the last.
    public static func band(_ stage: ReadProgress.Stage) -> ClosedRange<Double> {
        switch stage {
        case .sizing: 0.00...0.20
        case .transcribing: 0.00...0.25
        case .course: 0.20...0.25
        case .grading: 0.25...0.32
        case .obligations: 0.32...0.85
        case .policies: 0.85...0.92
        case .breaks: 0.92...0.96
        }
    }

    /// How far along the part is: the stage's band, filled by its items when the total is known, else its start.
    public static func fraction(_ progress: ReadProgress) -> Double {
        let band = band(progress.stage)
        guard let total = progress.total, total > 0 else { return band.lowerBound }
        return band.lowerBound + (band.upperBound - band.lowerBound) * min(1, Double(progress.done) / Double(total))
    }

    /// Where the bar creeps toward while nothing arrives: the next item's share of the band, or the band's end.
    public static func mark(_ progress: ReadProgress) -> Double {
        let band = band(progress.stage)
        guard let total = progress.total, total > 0 else { return band.upperBound }
        return band.lowerBound + (band.upperBound - band.lowerBound) * min(1, Double(progress.done + 1) / Double(total))
    }

    /// The stage in the user's words with its count, widest first: "What's due · 8 of 18 · Quiz 8", then without the
    /// item's name, then the count alone. The line is short by design and the view shows the first wording that fits
    /// on one line (`lines`), so it never wraps, whatever the item is called or the type size.
    public static func captions(_ progress: ReadProgress) -> [String] {
        func counted(_ head: String, _ noun: String) -> [String] {
            if let total = progress.total {
                let count = "\(min(progress.done, total)) of \(total)"
                return ["\(head) · \(count)", "\(count) \(noun)"]
            }
            return progress.done > 0 ? ["\(head) · \(progress.done) so far", "\(progress.done) \(noun)"] : [head]
        }
        switch progress.stage {
        case .sizing:
            if let outline = progress.outline { return ["Measured: \(outline.titles.count) due"] }
            return progress.done > 0 ? ["Sizing it up · \(progress.done) due so far", "\(progress.done) due so far"] : ["Sizing it up…"]
        case .transcribing: return ["Reading the picture…", "Transcribing…"]
        case .course: return ["Who, where, when"]
        case .grading: return counted("How it's graded", "rows")
        case .obligations:
            guard let total = progress.total else { return counted("What's due", "due") }
            // The item being written is the next one: "8 of 18 · Quiz 8" while the eighth is under way.
            let count = "\(min(progress.done + (progress.current == nil ? 0 : 1), total)) of \(total)"
            return (progress.current.map { ["What's due · \(count) · \($0)"] } ?? []) + ["What's due · \(count)", "\(count) due"]
        case .policies: return counted("The fine print", "rules")
        case .breaks: return counted("Days off", "days off")
        }
    }

    /// The widest wording: what VoiceOver reads, and what a test pins.
    public static func caption(_ progress: ReadProgress) -> String { captions(progress)[0] }

    /// The whole line under the document's name, widest first: the part (when the read has several; "Resumed at" when
    /// it goes on from a checkpoint) before each wording of the stage, and the narrowest wording alone as the last
    /// resort. Between parts there is no stage, only the rows so far.
    public static func lines(_ progress: ReadProgress?, part: Int, of parts: Int, pickedUp: Bool = false, found: Int = 0) -> [String] {
        let wordings = progress.map(captions) ?? ["\(found) found so far"]
        guard parts > 1 else { return wordings }
        let labels = (pickedUp ? ["Resumed at part \(part) of \(parts)"] : []) + ["Part \(part) of \(parts)"]
        let all = labels.flatMap { label in wordings.map { "\(label) · \($0)" } } + [wordings[wordings.count - 1]]
        return all.sorted { $0.count > $1.count }
    }
}
