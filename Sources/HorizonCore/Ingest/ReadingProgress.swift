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

    /// The stage in the user's words, with its count: "What's due · HW 3 · 7 of 18".
    public static func caption(_ progress: ReadProgress) -> String {
        func counted(_ head: String) -> String { progress.total.map { "\(head) · \(min(progress.done, $0)) of \($0)" } ?? (progress.done > 0 ? "\(head) · \(progress.done) so far" : head) }
        switch progress.stage {
        case .sizing: return progress.outline != nil ? "Measured: \(progress.outline!.titles.count) things due" : progress.done > 0 ? "Taking the measure of it · \(progress.done) due so far" : "Taking the measure of it…"
        case .transcribing: return "Reading the picture, line by line…"
        case .course: return "The course itself: who, where, when"
        case .grading: return counted("How the grade adds up")
        case .obligations:
            guard let total = progress.total else { return counted("What's due") }
            let item = progress.current.map { " · \($0)" } ?? ""
            return "What's due\(item) · \(min(progress.done, total)) of \(total)"
        case .policies: return counted("The fine print")
        case .breaks: return counted("Days off and breaks")
        }
    }
}
