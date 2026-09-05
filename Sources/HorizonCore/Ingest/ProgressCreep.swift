import Foundation

/// A progress figure that keeps moving while the real one stands still, so a long think by the model still reads as
/// work. The bar steps up to each real figure and then creeps from it toward the next mark (the end of the part being
/// read) without reaching it, so the part finishing is still a step. It never moves backwards, and it is a pure
/// function of time, so a timeline can draw it frame by frame.
public struct ProgressCreep: Equatable, Sendable {
    /// The last real figure, in 0...1.
    public private(set) var real: Double
    /// The next mark: the creep stays short of it until the real figure passes it.
    public private(set) var mark: Double
    /// What the bar showed when the real figure last changed; the new curve starts there, so nothing jumps back.
    public private(set) var from: Double
    public private(set) var since: Date
    /// Seconds for the creep to cover about two thirds of the way to the mark.
    public var pace: TimeInterval = 20
    /// The creep stops this far along the way to the mark, leaving the rest for the real step.
    public var reach: Double = 0.9

    public init(real: Double, mark: Double, at time: Date) {
        self.real = min(1, max(0, real)); self.mark = min(1, max(self.real, mark)); from = self.real; since = time
    }

    /// A new real figure or mark. The bar steps up to the figure from wherever it was and creeps again from there.
    public mutating func update(real: Double, mark: Double, at time: Date) {
        let real = min(1, max(0, real)), mark = min(1, max(real, mark))
        guard real != self.real || mark != self.mark else { return }
        from = value(at: time)
        self.real = real; self.mark = mark; since = time
    }

    public func value(at time: Date) -> Double {
        let elapsed = max(0, time.timeIntervalSince(since))
        let floor = max(from, real)                                          // the creep may have run past a small real step
        let step = from + (floor - from) * (1 - exp(-elapsed / 0.15))       // up to the real figure in well under a second
        let target = floor + (mark - floor) * reach
        let creep = max(0, target - floor) * (1 - exp(-elapsed / pace))
        return min(1, step + creep)
    }
}
