import XCTest

/// Siri on a real device (Apple Intelligence), end to end: a sentence handed to Siri as if spoken
/// (`XCUISiriService.activate(voiceRecognitionText:)`: speech recognition is skipped, everything after it is real: Siri's
/// reading of the sentence, its choice of app and intent, the intent, the answer).
///
/// One sentence per test: on iOS 27.2 the sentence reaches Siri and Siri answers, but XCUITest never sees Siri come up,
/// so `activate` waits a minute and ends the test. What Siri shows is read from screenshots taken from the Mac meanwhile
/// (`xcrun devicectl device capture screenshot`). AppIntentsTesting does not load on an OS newer than Xcode's, so the
/// course the run is added to is set up and cleared by the app's DEBUG flags (`--seed-siri-test`, `--clear-siri-test`).
///
/// It acts on the device's own library, so it runs only on a device and only when asked: TEST_RUNNER_HORIZON_SIRI=1
/// (xcodebuild hands TEST_RUNNER_ variables to the tests, without the prefix), and a confirmation is tapped only when
/// it names the test's own course.
/// env TEST_RUNNER_HORIZON_SIRI=1 xcodebuild test -project Horizon.xcodeproj -scheme Horizon -destination 'platform=iOS,id=<udid>' -allowProvisioningUpdates -only-testing:HorizonSiriTests
final class SiriOnDeviceTests: XCTestCase {
    static let testCourse = "Siri Test"

    override func setUp() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Siri is tested on a device.")
        #else
        guard ProcessInfo.processInfo.environment["HORIZON_SIRI"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_HORIZON_SIRI=1 to talk to Siri on this device.")
        }
        #endif
    }

    @MainActor func test1PolicyInHorizon() async throws { try await ask("What's the makeup exam policy for Calc in Horizon?") }
    @MainActor func test2DueThisWeek() async throws { try await ask("What's due this week in Horizon?") }
    @MainActor func test3NextByWeight() async throws { try await ask("What matters most next in Horizon?") }
    @MainActor func test4WeeklyRunUntilTheExam() async throws {
        try await ask("In Horizon, for \(Self.testCourse), add a task for every Thursday at 4pm and number them incrementally until the exam.")
    }

    /// Siri's confirmation of the run, tapped when it names the test's course; what it shows is kept either way.
    @MainActor func test5ConfirmTheRun() async throws {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let names = springboard.staticTexts.allElementsBoundByIndex.map(\.label)
        let buttons = springboard.buttons.allElementsBoundByIndex
        keep(name: "Siri's confirmation as SpringBoard sees it",
             words: names + buttons.map { "[\($0.label)]" } + ["", springboard.debugDescription])
        guard names.contains(where: { $0.contains(Self.testCourse) }),
              let add = buttons.first(where: { ["Add", "Confirm", "Yes", "Continue"].contains($0.label) }) else { return }
        add.tap()
        try await Task.sleep(for: .seconds(10))
        keep(name: "After confirming", words: springboard.staticTexts.allElementsBoundByIndex.map(\.label))
    }

    @MainActor private func ask(_ sentence: String) async throws {
        XCUIDevice.shared.press(.home)
        try await Task.sleep(for: .seconds(2))
        XCUIDevice.shared.siriService.activate(voiceRecognitionText: sentence)
        try await Task.sleep(for: .seconds(30))   // reached only once XCUITest sees Siri: then Siri has had its time
    }

    @MainActor private func keep(name: String, words: [String]) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        let text = XCTAttachment(string: words.joined(separator: "\n"))
        text.name = "\(name) (text)"
        text.lifetime = .keepAlways
        add(text)
    }
}
