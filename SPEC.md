# Build Spec — working title: **Horizon**

*Deviations are annotated inline, in italics after the statement (Superseded: what is true now, with the entry that decided it; Platform: what the SDK actually has), and logged in DECISIONS.md.*

A native iOS 27 / macOS 27 app. You are building this from scratch in Swift 6 / SwiftUI, targeting iOS 27 and macOS 27 (Golden Gate). Read this whole document before writing code. Ask me before deviating from the "Non-negotiables" section.

---

## 1. The thesis

**The problem is not forgetting tasks. It is not knowing a task exists.**

A university student's obligations live scattered across an LMS, a homework platform, a submission platform, a publisher's courseware, and a set of PDF syllabi. Several of these only announce themselves inside a lecture. Nothing aggregates them. The student's real failure mode is: *seven graded items were due in eight days and nobody ever told me.*

Once the full list exists in one place, planning a day takes five minutes. So this app is **not a planner**. It is an **intake engine** with a thin planner bolted on the end. Roughly 80% of the engineering value is in ingestion and gap detection. Build in that order.

---

## 2. Non-negotiables

These are product constraints, not preferences. Do not design around them.

1. **The user never types a task.** There is no "add task" form anywhere in the app. *(Superseded: Add Item… exists as a fallback, in menus only, its items marked `origin = manual`; DECISIONS 2026-09-04 «M2 setup», 2026-10-05 «Courses, tables on the paper, a still strip».)* Obligations enter the system by ingesting a document, a screenshot, or a calendar feed. If you find yourself building a task composer, stop and re-read this.
2. **The app must survive being abandoned.** Everything it learns is written out to EventKit (Reminders + Calendar). *(Superseded: Reminders only; the calendar is read for the day plan and never written; recorded in DECISIONS 2026-10-05 «Documentation checked against the code».)* If the user stops opening the app in week five, their deadlines still fire on their phone. Abandonment is a supported state, not a failure.
3. **No gamification.** No streaks, no scores, no completion percentages, no badges, no "you're on a 6-day run," no confetti, no red count badges. The user has explicitly said ranked/benchmarked interfaces demotivate him. Nothing in this app may accumulate guilt.
4. **The day plan is disposable.** Generated on demand, discarded after. *(Superseded: kept for its day, until 4 AM, so a relaunch keeps an edited plan; DECISIONS 2026-09-05 «A bar that keeps moving…», 2026-09-28 «The day ends when the student says».)* The next generation has no memory of whether the last one was followed. There is no "you completed 3 of 7 blocks yesterday."
5. **Local-first.** Parsing runs on-device by default. Nothing leaves the device unless the on-device model can't handle the document, and then it goes to Private Cloud Compute — which requires no API key and stores no prompts. *(Superseded: Claude reads documents, with the user's own key; the device model reads one only when the user picks it or confirms it as the fallback, and the day plan leaves the device only when the user asks; DECISIONS 2026-09-14 «Claude is the model…», 2026-10-05 «The audit».)*

---

## 3. Platform baseline

Target iOS 27 / macOS 27 / iPadOS 27. This app is a deliberate showcase of the WWDC26 frameworks; do not write compatibility shims for iOS 26.

Relevant facts about the platform you are building on:

- The on-device `SystemLanguageModel` is multimodal in iOS 27. It takes image attachments (`UIImage`, `NSImage`, `CGImage`, Core Image types, `CVPixelBuffer`, file URLs) at any size and aspect ratio, inserted into a prompt via `Attachment(...)` in the prompt builder. Larger images cost more tokens and latency.
- `PrivateCloudComputeLanguageModel` gives a 32,000-token context window and reasoning, controlled by `ContextOptions(reasoningLevel:)` with `.light` / `.deep`. No account setup, no auth, no API keys. Free of cloud API cost for developers with under 2 million lifetime first-time downloads. It requires an entitlement — check the PCC session/docs for the exact key. *(Platform: the options are `ContextOptions(includeSchemaInPrompt:reasoningLevel:)`, with `.light`, `.moderate`, `.deep` and `.custom`; the entitlement is `com.apple.developer.private-cloud-compute`.)* *(Superseded: not used; DECISIONS 2026-09-14 «Claude is the model…».)*
- `FoundationModels` ships system tools: `OCRTool` and `BarcodeReaderTool` (Vision-backed), plus a Spotlight-powered search tool for fully local RAG. *(Platform: the two are in Vision's cross-import overlay (FoundationModels with `import Vision`) and missing from the iOS simulator's SDK; the search tool is `SpotlightSearchTool`, in Core Spotlight's overlay.)* *(Superseded: `OCRTool` serves the device route only, and neither the barcode nor the search tool is used; DECISIONS 2026-09-14 «Claude is the model…».)*
- `LanguageModelSession.DynamicProfile` is the new declarative primitive for switching instructions, tools, model, and reasoning level mid-session while preserving transcript. *(Superseded: not used; each read and each plan makes its own sessions; DECISIONS 2026-09-04 «M1 parser CLI», 2026-10-05 «The audit».)*
- A `LanguageModel` protocol lets any provider back a session. Anthropic and Google publish conforming Swift packages. `CoreAILanguageModel` and `MLXLanguageModel` are open source for local models. *(Superseded: Anthropic's package is not used; the app calls the Messages API itself (`ClaudeClient`); DECISIONS 2026-09-14 «Claude is the model…».)*
- Sessions and responses expose `.usage` with input/output token counts, cached token count, and reasoning token count.
- `model.contextSize` and `model.tokenCount(for:)` exist — use them to adapt chunking to the hardware rather than hardcoding limits.
- **SiriKit is deprecated.** App Intents is the only path into Siri. Do not write SiriKit code.
- The `Evaluations` framework measures the quality of non-deterministic features.
- On macOS 27 there is an `fm` command-line tool and a Python SDK exposing the same on-device model.

---

## 4. Architecture

Three layers. Keep them separable; the ingestion layer should be a package that could ship on its own.

```
IngestKit      → documents in, structured Obligations out
HorizonCore    → storage, gap detection, collision detection, EventKit sync
Horizon        → SwiftUI app + widgets + App Intents
```

### 4.1 IngestKit

Entry points:

- **iOS Share extension** — accepts PDF, image, plain text, URL. *(Superseded: PDF, image and plain text, no web URL; a Word document is turned away with the reason; DECISIONS 2026-10-05 «The audit», «Documentation checked against the code».)*
- **macOS Quick Action / Services** + a watched folder (`~/Horizon Inbox`) via `FSEvents`. *(Superseded: no Quick Action or Services; the folder is watched with a dispatch source on it, not FSEvents; recorded in DECISIONS 2026-10-05 «Documentation checked against the code».)*
- **Shortcuts action** via App Intents so a screenshot can trigger ingest automatically.
- **ICS subscription** for any LMS that exposes a calendar feed. This path skips the model entirely — prefer it whenever available.

Pipeline:

1. Normalize input to either text (PDFKit) or images (page rasters, screenshots).
2. Check `model.contextSize`. If the document fits, one pass. If not, chunk by page with a rolling summary. *(Superseded: token-budgeted chunks with a small `RollingContext` between them, not a summary; Claude's chunks are 60k tokens, so a syllabus is one call; DECISIONS 2026-09-04 «M1 parser CLI», 2026-09-14 «Claude is the model…».)*
3. Run a `LanguageModelSession` in **ingest profile** (see 4.3) with `@Generable` structured output. *(Superseded: no profile, a fresh session per chunk on the device, and Claude's reply follows hand-written JSON schemas (`ClaudeSchemas`); DECISIONS 2026-09-04 «M1 parser CLI», 2026-09-14 «Claude is the model…».)*
4. Screenshots go in as image attachments directly — the model is multimodal now. Give it `OCRTool` as well so it can pull structured text when the layout is dense (a table of assignment rows, for example). *(Superseded: Claude transcribes a picture before reading its facts, so the guards have text to check against; `OCRTool` serves the device route only; DECISIONS 2026-09-14 «Claude is the model…».)*
5. Return `[ParsedObligation]` plus a `ParseConfidence` per item.
6. Anything below the confidence threshold goes to a **review queue** — a single screen where the user confirms or corrects with one tap. Never silently drop a low-confidence item, and never silently write one either.

### 4.2 Data model

```swift
struct Course: Identifiable {
    let id: UUID
    var code: String          // "MA-UY 1124"
    var title: String         // "Calculus II"
    var instructor: String?
    var meetingPattern: [MeetingSlot]
    var gradeComponents: [GradeComponent]   // parsed from the syllabus
    var platforms: [Platform]  // .lms, .webAssign, .gradescope, .myLab, .syllabusOnly
    var lastIngested: Date
}

struct GradeComponent {
    var name: String          // "Quizzes"
    var weight: Double        // 0.12
    var cadence: Cadence?     // .weekly(.thursday), .none
}

struct Obligation: Identifiable {
    let id: UUID
    var courseID: Course.ID
    var title: String
    var due: Date
    var dueHasTime: Bool
    var platform: Platform
    var componentName: String?    // links to GradeComponent
    var pointsAtStake: Double?    // derived: weight ÷ expected item count
    var sourceDocumentID: UUID    // provenance, always
    var confidence: Double
    var ekExternalID: String?     // calendarItemExternalIdentifier — see §4.4
    var userOverrides: Set<FieldKey> = []   // fields the user edited by hand
    var deletedAt: Date?          // soft delete; see §4.4
}
```

**Provenance is mandatory.** Every obligation knows which document it came from and links back to it. When the user asks "where did this come from," the answer is one tap away. This is what makes an automated parser trustworthy.

### 4.3 Dynamic Profiles

Use one `DynamicProfile` with three branches. This is the right primitive here because ingestion and planning want different models but should share a transcript. *(Superseded: none of this was built: no profile, no askMyDocuments, no tools (the planner's prompt carries the calendar and the items), no PCC; DECISIONS 2026-09-04 «M1 parser CLI», 2026-09-14 «Claude is the model…», 2026-10-05 «The audit».)*

```swift
struct HorizonProfile: LanguageModelSession.DynamicProfile {
    let state: AppState

    var body: some DynamicProfile {
        switch state.mode {
        case .ingest:
            // cheap, private, high volume, multimodal
            Profile {
                Instructions { /* extract obligations; see §5 */ }
                OCRTool()
                RecordObligationTool(store: state.store)
            }

        case .askMyDocuments:
            // local RAG over the user's own syllabi
            Profile {
                Instructions { /* answer only from indexed course documents */ }
                SpotlightSearchTool()   // system tool
            }

        case .plan:
            // needs judgment and a long context: escalate
            Profile {
                Instructions { /* see §6 */ }
                FetchCalendarTool()
                FetchObligationsTool(store: state.store)
            }
            .model(state.privateCloudCompute)
            .reasoningLevel(.deep)
        }
    }
}
```

Log `response.usage` on every call and surface a small debug view showing token counts. You will need it to tune chunking. *(Superseded in part: usage is logged on every call, but only each document's tokens and time are shown, in Documents; recorded in DECISIONS 2026-10-05 «Documentation checked against the code».)*

### 4.4 Storage and sync

Read this section twice. There are **two independent sync systems** operating over the same data — CloudKit syncing the app's store, and iCloud syncing Reminders and Calendar underneath EventKit. Most of the bugs in this app will come from that fact.

#### The store

SwiftData, in an **App Group container** so the share extension and the macOS folder watcher write to the same store as the app: *(Superseded on the Mac: no App Group; the store is in Application Support and the Inbox folder is read by the app itself; DECISIONS 2026-09-08 «The Mac gets a Mac».)*

```swift
let config = ModelConfiguration(
    groupContainer: .identifier("group.<bundle-prefix>.horizon"),
    cloudKitDatabase: .private("iCloud.<bundle-prefix>.horizon")
)
```

*(Superseded: `cloudKitDatabase: .none` unless the `HORIZON_CLOUDKIT` flag is set, which needs a paid team; DECISIONS 2026-09-04 «M2 setup», 2026-10-05 «The audit».)*

SwiftData's CloudKit mirroring imposes hard schema constraints. Violating any of these fails at container init, not at compile time:

- Every property must be **optional or have a default value**.
- **No `@Attribute(.unique)`.** Enforce uniqueness in application code (see idempotency below), not in the schema.
- Every relationship must be optional and must have an explicit inverse.
- No `@Attribute(.allowsCloudEncryption)` on anything you need to query on.

Store the original source documents with `@Attribute(.externalStorage)` but **do not sync them.** *(Superseded: the files sit on disk under their hash, outside the model, and `SourceDocument` holds the metadata; DECISIONS 2026-09-04 «M2 setup».)* A semester of syllabus PDFs is tens of megabytes and syncing them buys nothing. Sync a small `SourceDocument` record instead — filename, SHA-256, page count, ingest date, originating device name. Provenance links open the file on the device that ingested it; other devices show "ingested on <device>, not available here." Use the hash to skip re-ingesting a document the user shares twice.

Adopt `VersionedSchema` and `SchemaMigrationPlan` from the first commit, before there's any data to migrate. The CloudKit production schema is **append-only** once deployed — you can add fields and record types forever, but you can never remove or retype one. Getting this wrong in week two means a new container and abandoned user data.

#### Idempotency — the trap that will bite you

Device A ingests a syllabus and creates 22 reminders. CloudKit syncs the `Obligation` records to device B. Device B sees 22 obligations with no local reminder and creates 22 more. Meanwhile iCloud has already synced device A's reminders to device B. The user now has 44 reminders.

Solution — **never derive "does a reminder exist" from local state.** Two rules:

1. Key on `EKCalendarItem.calendarItemExternalIdentifier`, not `calendarItemIdentifier`. The former is stable for the same item across devices; the latter is device-local and will not match. Store it on the `Obligation` and sync it.
2. Before creating any reminder, re-fetch the Horizon list and match against existing items by external ID. Create only on a genuine miss. Treat this fetch-then-write as the only sanctioned write path — put it behind a single actor so no two code paths can race it.

If an obligation has a null `ekExternalID` **and** no matching item is found, create. Any other combination is a no-op or a repair.

#### Field ownership — not last-writer-wins

Blanket last-writer-wins is wrong here, because different fields have different authorities. Define ownership explicitly:

| Field | Authority | Behavior |
|---|---|---|
| title, due date, weight, platform | the source document | Re-ingesting the same document updates these — **unless** the field is in `userOverrides`, in which case ingest surfaces a conflict instead of overwriting *(Superseded: the hand edit stays and a `changeNote` says what the document now says, without review; DECISIONS 2026-09-04 «M2 review fixes».)* |
| completion state | EventKit | The user checks things off in Reminders; the app reads that direction only *(Superseded: the app checks items off too, a request the projector writes to the reminder, after which Reminders' word wins again; DECISIONS 2026-09-20 «One-line captions…».)* |
| notes, snooze, manual reschedule | the user | Set the corresponding `FieldKey` in `userOverrides` on any hand edit |
| confidence, provenance, points at stake | the app | Derived; never user-editable |

Re-ingesting an updated syllabus is a normal operation, not an edge case — professors reissue them. The behavior must be: match existing obligations by (course, component, due date) fuzzy key, update what the document owns, leave overrides alone, and present anything that changed as a diff the user confirms. *(Superseded: matched in passes on the title and day the document last gave each row (`documentWords`); a changed title, date or site goes to review with a `changeNote`; DECISIONS 2026-09-04 «M2 review fixes», 2026-10-05 «The audit».)* Never silently move a date the user is relying on.

#### Reconciliation

Subscribe to `.EKEventStoreChanged` and reconcile on app foreground. The reconciler is one function, always safe to run twice:

1. Fetch all items in the Horizon list.
2. Match to obligations by external ID.
3. Item exists, obligation doesn't → the user created it manually in Reminders. Import it as an unattributed obligation; do not delete it.
4. Obligation exists, item doesn't → the user deleted it in Reminders. *(Superseded: only for reminders this device has seen, and a missing list deletes nothing; DECISIONS 2026-09-04 «M2 review fixes», 2026-09-27 «The Horizon list, deleted and made again».)* **Treat deletion as intent**, soft-delete the obligation, and do not recreate it. Recreating deleted reminders is the single most infuriating thing a sync app can do.
5. Both exist, completion differs → EventKit wins.
6. Both exist, content differs → apply the ownership table.

#### Deletes

SwiftData + CloudKit propagates deletes unreliably in practice, especially to a device that was offline when the delete happened. Use **soft deletes** — set `deletedAt`, filter every query on `deletedAt == nil`, and purge tombstones older than 180 days on a device that has been online recently. Never hard-delete a record that has ever synced. *(Superseded: the purge runs on every pass, online or not, and an erased document's record goes with its file: harmless while nothing syncs, wrong once CloudKit mirrors; DECISIONS 2026-09-07 «Recently Deleted…», 2026-10-05 «Documentation checked against the code».)*

#### Offline

Ingestion must work with no network — on-device parsing already does. Stage parse results in a local queue with a status enum (`.pendingReview`, `.readyToProject`, `.projected`). EventKit writes are local and work offline; CloudKit catches up on its own. The one operation that genuinely requires network is the Private Cloud Compute fallback for oversized documents: queue those as `.awaitingCloudParse` and retry with `BGProcessingTask`, and tell the user plainly that the document is queued rather than silently doing nothing. *(Superseded: every Claude read needs the network, and `awaitingCloudParse` means waiting for Claude; DECISIONS 2026-09-14 «Claude is the model…».)*

#### What to test

Write these as integration tests before building the UI, because they are not reproducible by hand:

- Two devices ingest the same document within seconds of each other → exactly one set of reminders.
- Device offline for a week, obligations edited on both sides → no duplicates, overrides preserved.
- User deletes a reminder in Apple Reminders → it stays deleted through three reconciliation cycles.
- Re-ingest a revised syllabus where three dates moved → diff presented, overridden fields untouched.
- Share extension writes while the main app is suspended → single store, no container conflict.

---

## 5. The ingest prompt

Structured output via `@Generable`. *(Superseded for Claude: hand-written JSON schemas, in the order the model writes (`ClaudeSchemas`); `@Generable` stays for the device; DECISIONS 2026-09-14 «Claude is the model…».)* The extraction schema must pull:

- course identity (code, title, instructor, meeting pattern, room)
- **the grade breakdown table** — this is not optional, it's what makes ordering possible
- every dated obligation with platform attribution
- stated policies worth surfacing later: late-work policy, makeup-exam procedure, attendance weight, drop rules ("lowest three dropped"), extra-credit deadlines
- explicit "no class" dates (holidays, breaks)

Rules for the model, stated in `Instructions`:

- Never invent a date. If a date is stated as TBD, emit the obligation with a null due date and a `.awaitingDate` status.
- Preserve exact wording for policy strings; paraphrase nothing.
- If two documents disagree about the same obligation, emit both and flag the conflict rather than picking one. *(Superseded: across documents the item stays one row, the other date kept as `conflictingDate` for review ("Use <the other date>"); within one document both are kept and flagged; DECISIONS 2026-09-04 «M1 parser CLI», 2026-09-05 «Several documents per course», 2026-10-05 «The audit».)* (Real case: a syllabus said one date, the professor announced another. The app's job is to surface the discrepancy, not resolve it.)

---

## 6. The three screens that matter

Everything else is chrome. Build these three well and ship.

### 6.1 Coverage — *the differentiating screen*

Not a task list. A view of **where the app is probably blind.**

For each course, compute and display:
- days since last ingest *(Superseded: days since the course's last completed item; when it was last read is the quiet "Updated N days ago"; DECISIONS 2026-09-27 «Days silent are the user's».)*
- number of obligations in the next 14 days
- whether the parsed grade components imply a cadence that isn't showing up ("syllabus says quizzes every 1–2 weeks; zero quiz obligations on file")
- which platforms for this course have never been ingested at all

Sort by suspicion, not by course name. *(Superseded: the user's own order first, suspicion only for courses without a place; DECISIONS 2026-09-05 «UI pass from the user's review».)* The headline state is *"Bio has been silent for 9 days and its syllabus implies weekly quizzes."* That sentence is the product. *(Superseded: the sentence is what VoiceOver reads; the page shows one short line per finding; DECISIONS 2026-09-27 «Coverage, cleaned up».)*

### 6.2 Horizon — the semester strip

A single continuous horizontal strip of the term. Not a month grid — a month grid destroys the thing that matters, which is density and collision.

- Each obligation is a mark whose **visual mass is its points at stake**, not its item count. A 30% final is a heavy mark; a 4% problem set is a hairline. *(Superseded: load is colour, not size: a week's or a day's cell deepens with the points at stake not yet done; DECISIONS 2026-09-05 «A bar that keeps moving…».)*
- Marks from different courses occupy different bands.
- **Collision days** — two or more high-weight items within 24 hours across courses — render as a visible pileup with the day called out. *(Superseded: two or more items of 10 points or more, each within a day of the one before, of one course or several; DECISIONS 2026-09-05 «M4 Horizon strip», 2026-10-05 «Documentation checked against the code».)* Two exams ninety minutes apart on the same morning should be immediately, physically obvious.
- Pinch to zoom from full-semester to two-week. Scrubbing is the primary interaction. *(Superseded: two levels on iOS, the semester to read and the days to work from, and a tap chooses; one level on a Mac, read by pointing; DECISIONS 2026-09-20 «The strip, rebuilt…», «The semester is for reading…», 2026-09-28 «The Mac, set for a window».)*

This screen is the reason someone would open the app for pleasure rather than obligation. Spend real time on it.

### 6.3 Now — the disposable day plan

One button. It reads Calendar for hard constraints (classes, appointments, anything with a fixed time), takes the free gaps, and returns an ordered set of blocks with reasons attached — "this first, because it's the prerequisite check for tomorrow's quiz." *(Superseded in part: a study session or library time on the calendar is coursework time to fill, the rest hard stops; DECISIONS 2026-09-27 «The plan reads the calendar, and a test is studied for».)*

- Generated by the `.plan` profile on PCC with `.deep` reasoning. *(Superseded: the device model, or Claude at low effort when the user turns planning with Claude on; DECISIONS 2026-09-05 «M5 Now», 2026-09-14 «Claude is the model…», 2026-09-27 «The plan reads the calendar…».)*
- Includes non-work blocks. If the user hasn't eaten, the first block is eating. If a parking permit or a commute is on the calendar, it's a hard stop in the plan.
- No persistence. Closing the screen discards it. *(Superseded: kept for its day, until 4 AM; tomorrow's still starts from nothing; DECISIONS 2026-09-05 «A bar that keeps moving…», 2026-09-28 «The day ends when the student says».)* Tomorrow's plan does not reference today's.

---

## 7. System integration

Implement in this order:

1. **EventKit write-out.** Do this first — it's what makes the app useful before any UI exists.
2. **App Intents.** `IngestDocumentIntent`, `WhatsDueIntent`, `GenerateDayPlanIntent`. Conform `Obligation` and `Course` to `AppEntity`. Adopt `IndexedEntity` with `indexingKey` on title, course, and platform so Siri can do semantic search over obligations and Spotlight surfaces them with attribution. Adopt the relevant **App Schemas** rather than inventing bespoke phrasing — the system-defined schemas improve as Siri's language understanding does, with no code change. Include `.system.searchInApp`. *(Superseded: the intents are `ReadDocumentIntent`, `GetItemsIntent` (what's due, and every other question about items) and `PlanDayIntent`, among twenty-three that reach every function but erasing, one per verb and kind of thing with its variants as parameters (DECISIONS 2026-10-13); Siri's own model reaches the schema intents, and the rest through seven App Shortcuts; the entities are values made from the store's snapshots (`ItemEntity`, `CourseEntity`; policies, documents and plan blocks too), since a SwiftData row cannot leave its context; items adopt the reminders schema, courses its lists, grade rows its sections and policies the notes schema; the index takes the title, the course's name and code, the grade row and the site through `attributeSet`, which covers the schema's own properties as well; DECISIONS 2026-10-05 «App Intents».)*
3. **Widgets.** Lock screen widget showing the single next obligation ranked by points at stake — not by date. Home screen medium widget showing the next seven days of the Horizon strip. *(Superseded: the next obligation is the heaviest open one due in the next two weeks, so a final months away does not stand there all term; iOS only, since the Mac has no App Group for the widgets to read from; DECISIONS 2026-10-05 «App Intents».)*
4. **Share extension + macOS watched folder.**
5. **View Annotations API** so the user can look at an obligation on screen and say "push this to Sunday" and Siri resolves "this" to that entity.
6. **Control Center control** for one-tap ingest of the current screenshot. *(Platform: no API lets a control capture the screen. Superseded: the control opens Horizon at Photos' screenshots, and the user picks the one just taken; DECISIONS 2026-10-05 «App Intents».)*
7. **App Intents Testing framework** — validate the Siri, Shortcuts, and Spotlight paths through real system pathways rather than UI automation.

Declare per-intent cloud-routing in the privacy manifest. Ingest intents should be declared on-device-only; the planning intent may route to PCC. *(Platform: a privacy manifest has no such key; it declares tracking, the data collected and the required-reason APIs. Superseded: an intent sends what the app's own action would, under the user's switches (documents to Claude only on the reading route, the plan only with "Plan the day with Claude"), and the two intents that turn a switch on ask first; Private Cloud Compute is not used; DECISIONS 2026-09-14 «Claude is the model…», 2026-10-05 «App Intents».)*

---

## 8. Evaluations

Parsing is the product, and it's non-deterministic, so it needs measurement, not vibes.

Set up the `Evaluations` framework with a fixture set of at least 15 real syllabi across departments — PDFs with tables, scanned ones, docx exports, screenshots of assignment lists. *(Superseded: 19 fixtures, 15 synthetic in those forms and 4 real; DECISIONS 2026-09-04 «M1 parser CLI», 2026-09-05 «Real fixtures».)* Score on:

- obligation recall (did it find every dated item?)
- date accuracy
- grade-component weight accuracy
- false-positive rate (invented obligations — this should be zero, weight it heavily)

Run the suite on every prompt change. Recall matters more than precision here: a missed obligation is the exact failure the app exists to prevent, while a spurious one costs a tap in the review queue.

---

## 9. Visual direction

The wrong instinct is a productivity app. The right reference is editorial design — a well-set magazine spread.

- Single column, generous whitespace, large type. Let the type carry hierarchy instead of boxes and cards. *(Superseded on the Mac: its pages use the window's width, in columns; DECISIONS 2026-09-28 «The Mac, set for a window».)*
- Dark by default. One accent color, used sparingly and only for weight/urgency. *(Superseded: the app follows the system's appearance (DECISIONS 2026-09-04 «M2 setup»); the accent also marks selection and controls, in a deeper ink for words (2026-09-20 «One-line captions…», 2026-10-05 «The audit»).)*
- Adopt Liquid Glass properly — iOS 27 tightened these rules and half-adopting it looks worse than not adopting it. Read the current HIG before styling anything.
- No red badge counts anywhere in the app or on the icon.
- Numbers should be typographically confident: real tabular figures, generous size, no tiny gray metadata rows.
- Animation only where it carries meaning — the Horizon scrub, and the moment a document resolves into a set of obligations. Nothing decorative.

---

## 10. Build order

Ship each milestone as something usable on its own.

1. **M1 — Parser CLI.** A macOS command-line target. Feed it a syllabus PDF, print structured JSON. No UI, no storage. Get extraction quality right in isolation, with the eval suite running.
2. **M2 — Ingest to Reminders.** Add the share extension and EventKit write-out. At this point the app is genuinely useful with no interface at all.
3. **M3 — Coverage screen.** Gap detection over the local store.
4. **M4 — Horizon strip.** Weights, collisions, zoom.
5. **M5 — Now.** Day-plan generation on PCC. *(Superseded: on the device, or Claude when the user turns it on; DECISIONS 2026-09-05 «M5 Now», 2026-09-14 «Claude is the model…».)*
6. **M6 — Siri, widgets, View Annotations.**

Stop after each milestone and show me before continuing.

---

## 11. Explicitly out of scope

Don't build these, don't propose them:

- Any account system or backend. There is no server.
- Social features, sharing, comparison with other students.
- Notifications the app sends itself. Reminders and Calendar handle notification; the app doesn't compete with them.
- Pomodoro timers, focus sessions, time tracking.
- Scraping LMS platforms with stored credentials. Use ICS feeds where they exist and document ingest where they don't. Never ask for an LMS password.
- Anything that requires daily user input to stay accurate.
