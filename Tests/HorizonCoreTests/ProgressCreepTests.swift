import Foundation
import Testing
@testable import HorizonCore

struct ProgressCreepTests {
    static let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
    static func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    @Test func creepsTowardTheMarkWhileTheRealFigureStandsStill() {
        let creep = ProgressCreep(real: 0.2, mark: 0.4, at: Self.at(0))
        #expect(creep.value(at: Self.at(0)) == 0.2)
        let samples = stride(from: 0.0, through: 120, by: 1).map { creep.value(at: Self.at($0)) }
        #expect(zip(samples, samples.dropFirst()).allSatisfy { $0 < $1 })          // always moving
        #expect(samples[5] - samples[0] > 0.02)                                     // visibly, within seconds
        #expect(samples.last! < 0.2 + 0.2 * 0.9 && samples.last! > 0.37)            // toward the mark, never reaching it
    }

    @Test func stepsUpToANewFigureWithoutJumpingBack() {
        var creep = ProgressCreep(real: 0.2, mark: 0.4, at: Self.at(0))
        let before = creep.value(at: Self.at(30))
        creep.update(real: 0.4, mark: 0.6, at: Self.at(30))
        #expect(creep.value(at: Self.at(30)) == before)                             // continuous at the change
        #expect(creep.value(at: Self.at(31)) > 0.399)                               // and up to the figure within a second
        #expect(creep.value(at: Self.at(31)) < 0.6)
        // A real figure the creep had already passed holds the bar where it was.
        creep.update(real: 0.41, mark: 0.6, at: Self.at(40))
        let held = creep.value(at: Self.at(40))
        #expect(held >= 0.41 && creep.value(at: Self.at(41)) >= held)
    }

    @Test func clampsToOne() {
        var creep = ProgressCreep(real: 0.95, mark: 1.5, at: Self.at(0))
        #expect(creep.mark == 1)
        #expect(creep.value(at: Self.at(600)) <= 1)
        creep.update(real: 2, mark: 2, at: Self.at(1))
        #expect(creep.value(at: Self.at(2)) <= 1 && creep.value(at: Self.at(2)) > 0.99)
    }
}
