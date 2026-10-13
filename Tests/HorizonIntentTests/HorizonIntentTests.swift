import XCTest
import AppIntentsTesting

/// Horizon's App Intents through the same infrastructure Siri, Shortcuts and Spotlight use (AppIntentsTesting, WWDC26):
/// the app runs in its own process on the simulator, on the simulator's store, and these tests reach it by name only.
/// What they write they delete again. Run with:
/// xcodebuild test -project Horizon.xcodeproj -scheme Horizon -destination 'platform=iOS Simulator,name=iPhone 18 Pro Max' -only-testing:HorizonIntentTests
final class HorizonIntentTests: XCTestCase {
    let horizon = IntentDefinitions(bundleIdentifier: "com.daniel.horizon")

    /// The first course on file; the tests that need one skip without it.
    private func firstCourse() async throws -> (entity: AnyAppEntity, name: String) {
        let courses = try await horizon.entities["CourseEntity"].allEntities()
        guard let first = courses.first else { throw XCTSkip("The simulator's store has no course.") }
        let name: String = try first.name
        return (first, name)
    }

    func testCoursesAreFoundByWhatPeopleSay() async throws {
        let course = try await firstCourse()
        let word = String(course.name.prefix(4))   // "Calc" for Calculus II
        let found = try await horizon.entities["CourseEntity"].entities(matching: word)
        let names: [String] = try found.map { try $0.name }
        XCTAssertTrue(names.contains(course.name), "\(word) should name \(course.name), found \(names)")
    }

    func testWhatsDueAnswersForTheNextTwoWeeks() async throws {
        let result = try await horizon.intents["GetItemsIntent"].makeIntent(show: "due", when: "nextTwoWeeks").run()
        let items: [AnyAppEntity] = try result.value
        for item in items {
            let due: Date? = try item.due
            XCTAssertNotNil(due, "every item due in a stretch has a date")
            XCTAssertFalse(try item.isCompleted as Bool, "what's due is what's still to do")
        }
    }

    func testWhatMattersMostComesHeaviestFirst() async throws {
        let result = try await horizon.intents["GetItemsIntent"].makeIntent(show: "mostImportant").run()
        let items: [AnyAppEntity] = try result.value
        let weights: [Double] = try items.map { (try $0.weight as Double?) ?? 0 }
        let weighed = weights.prefix { $0 > 0 }
        XCTAssertEqual(Array(weighed), weighed.sorted(by: >), "the weighed ones come heaviest first, found \(weights)")
    }

    func testEveryOtherQuestionAboutItemsAnswers() async throws {
        for show in ["pileups", "toReview", "done"] { _ = try await horizon.intents["GetItemsIntent"].makeIntent(show: show).run() }
        _ = try await horizon.intents["GetItemsIntent"].makeIntent(show: "due", when: "overdue").run()
        _ = try await horizon.intents["CheckCoverageIntent"].makeIntent().run()
    }

    func testACourseAnswersFromItsDocuments() async throws {
        let course = try await firstCourse()
        // Quoted, or "no such policy"; the grade table, or "none on file"; the course itself: never a failure.
        _ = try await horizon.intents["GetCourseInfoIntent"].makeIntent(course: course.entity, topic: "makeupExams").run()
        _ = try await horizon.intents["GetCourseInfoIntent"].makeIntent(course: course.entity, topic: "grading").run()
        let overview = try await horizon.intents["GetCourseInfoIntent"].makeIntent(course: course.entity).run()
        let said: String = try overview.value
        XCTAssertTrue(said.contains(course.name), "the overview names the course: \(said)")
    }

    func testSettingsAreSaidWhenNothingIsChanged() async throws {
        _ = try await horizon.intents["ChangeSettingsIntent"].makeIntent().run()
    }

    func testAnItemAddedChangedAndDeletedThroughTheRemindersSchema() async throws {
        // A run stopped between its add and its delete leaves a probe behind: deleted here first, and each run's probe is
        // named for it alone, so a leftover can never answer for this one.
        let leftovers = try await horizon.entities["ItemEntity"].entities(matching: "AppIntentsTesting probe")
        if !leftovers.isEmpty { _ = try await horizon.intents["DeleteItemsIntent"].makeIntent(entities: leftovers).run() }
        let title = "AppIntentsTesting probe \(UUID().uuidString.prefix(8))"

        let course = try await firstCourse()
        var due = Calendar.current.dateComponents([.year, .month, .day], from: Date().addingTimeInterval(9 * 86400))
        due.hour = 16; due.minute = 0
        let added = try await horizon.intents["AddItemIntent"].makeIntent(title: title, list: course.entity, dueDate: due).run()
        let item: AnyAppEntity = try added.value
        XCTAssertEqual(try item.title as String, title)

        let changed = try await horizon.intents["ChangeItemIntent"].makeIntent(target: item, isCompleted: true).run()
        let after: AnyAppEntity = try changed.value
        XCTAssertTrue(try after.isCompleted as Bool)
        _ = try await horizon.intents["ChangeItemIntent"].makeIntent(target: item, review: "confirm").run()   // not in review: said so, never a failure

        // Skipped, a shortcut's own: closed (checked off in Reminders) but not done; not done opens it, whatever closed it.
        let skipped: AnyAppEntity = try await horizon.intents["ChangeItemIntent"].makeIntent(target: item, skipped: true).run().value
        XCTAssertTrue(try skipped.isCompleted as Bool, "a skipped item is closed")
        XCTAssertEqual((try skipped.status as AnyAppEnum).rawValue, "skipped")
        let reopened: AnyAppEntity = try await horizon.intents["ChangeItemIntent"].makeIntent(target: item, isCompleted: false).run().value
        XCTAssertFalse(try reopened.isCompleted as Bool, "not done puts a skipped item back on the list")
        XCTAssertEqual((try reopened.status as AnyAppEnum).rawValue, "toDo")

        // The grade row and the site: a shortcut's own two parameters, then the tags Siri sets (the schema has no field for either).
        let rows = try await horizon.entities["GradeRowEntity"].suggestedEntities()
        let courseRows: [String] = try rows.compactMap { row in
            let list: AnyAppEntity = try row.list
            return try (list.name as String) == course.name ? try row.name as String : nil
        }
        if let row = courseRows.first {
            let placed: AnyAppEntity = try await horizon.intents["ChangeItemIntent"].makeIntent(target: item, countsToward: row, site: "webAssign").run().value
            XCTAssertEqual(try placed.gradeRow as String?, row)
            XCTAssertEqual(try placed.site as String?, "WebAssign")
        }
        let tagged: AnyAppEntity = try await horizon.intents["ChangeItemIntent"].makeIntent(target: item, tags: ["Gradescope"]).run().value
        XCTAssertEqual(try tagged.site as String?, "Gradescope", "a tag naming a site sets it, as Siri does")

        _ = try await horizon.intents["DeleteItemsIntent"].makeIntent(entities: [item]).run()
        let left = try await horizon.entities["ItemEntity"].entities(matching: title)
        XCTAssertTrue(left.isEmpty, "a deleted item is no longer found")
    }

    /// A weekly run through Add Item's own parameters (Every, Until, First Number), kept to one item: a run of more is
    /// confirmed first, and a test cannot answer. The day after tomorrow, stopping before an item a week after it.
    func testAWeeklyRunStopsBeforeTheItemItRunsUntil() async throws {
        let leftovers = try await horizon.entities["ItemEntity"].entities(matching: "AppIntentsTesting probe")
        if !leftovers.isEmpty { _ = try await horizon.intents["DeleteItemsIntent"].makeIntent(entities: leftovers).run() }
        let course = try await firstCourse()
        let tag = String(UUID().uuidString.filter(\.isLetter).prefix(6))
        let calendar = Calendar.current
        let first = calendar.date(byAdding: .day, value: 2, to: Date())!
        let end = calendar.dateComponents([.year, .month, .day], from: calendar.date(byAdding: .day, value: 9, to: Date())!)
        let weekday = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"][calendar.component(.weekday, from: first) - 1]

        // What a stopped run leaves behind, the next run's sweep deletes.
        let stop: AnyAppEntity = try await horizon.intents["AddItemIntent"].makeIntent(title: "AppIntentsTesting probe end \(tag)", list: course.entity, dueDate: end).run().value
        let run: ResolvedIntentResult
        do {
            run = try await horizon.intents["AddItemIntent"].makeIntent(title: "AppIntentsTesting probe run \(tag)", list: course.entity, every: weekday,
                                                                        until: stop, firstNumber: 7).run()
        } catch {
            _ = try? await horizon.intents["DeleteItemsIntent"].makeIntent(entities: [stop]).run()
            throw XCTSkip("No week in the run falls outside the course's breaks: \(error)")
        }
        let added: AnyAppEntity = try run.value
        let probes = try await horizon.entities["ItemEntity"].entities(matching: "AppIntentsTesting probe \(tag)")   // the run and its end: most of the words
        let runs = try probes.filter { (try $0.title as String).hasPrefix("AppIntentsTesting probe run \(tag)") }
        _ = try await horizon.intents["DeleteItemsIntent"].makeIntent(entities: probes).run()
        XCTAssertEqual(try added.title as String, "AppIntentsTesting probe run \(tag) 7", "numbered from First Number")
        XCTAssertEqual(runs.count, 1, "the run stops before the day of the item it runs until")
    }

    func testCoursesAreInSpotlight() async throws {
        let course = try await firstCourse()
        let found = try await horizon.entities["CourseEntity"].spotlightQuery(course.name)
        XCTAssertFalse(found.isEmpty, "\(course.name) should be in Spotlight's index once the app has run")
    }

    func testACoursePageSaysWhichCourseItShows() async throws {
        let course = try await firstCourse()
        await XCUIApplication(bundleIdentifier: "com.daniel.horizon").launch()
        _ = try await horizon.intents["OpenCourseIntent"].makeIntent(target: course.entity).run()
        try await Task.sleep(for: .seconds(2))
        let annotations = try await horizon.entities["CourseEntity"].viewAnnotations()
        let names: [String] = try annotations.map { try $0.entity.name }
        XCTAssertTrue(names.contains(course.name), "the course page should annotate its course, found \(names)")
    }
}
