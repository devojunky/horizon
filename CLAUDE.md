# Horizon

Native iOS 27 / macOS 27 app: an intake engine that turns course documents into obligations and writes them to EventKit. Spec: `SPEC.md`. Deviations and choices: `DECISIONS.md`.

## Layout
```
Package.swift             SwiftPM. Targets: IngestKit, HorizonCore (libs), HorizonParse (CLI), IngestKitTests, HorizonCoreTests, IngestEvals
project.yml               xcodegen spec for the app targets; Horizon.xcodeproj is generated and git-ignored
Apps/Horizon/             SwiftUI app (iOS + macOS): FeatureFlags (openAI on/off), Keychain (the OpenAI key), SettingsView (reading route, OpenAI key + model + test, device, DEBUG sample), Design (tokens, type, shared pieces), AppModel (store/coordinator/sync wiring, live Reading state, cancel, the reading route, the day plan kept for the day + its edits + what the user tells the planner, bin actions), HorizonStripView (MainTabs + the M4 strip: weeks/days/items by zoom, heat cells, range tabs), NowView (M5 day plan as a timetable), PlanEditors (block editor, Tell the Planner), RootView (Coverage; `Route` + the guarded push every page uses; pull to refresh; ReadingSection with the creeping bar; RecentlyDeletedRow), CoverageView, ReviewView, ObligationEditor, CourseView, DocumentsView, RecentlyDeletedView (the bin: restore / delete now), ImportSources (Files / Photos / document camera), WatchedFolder (macOS)
Apps/HorizonShare/        iOS share extension: copies the shared file into the App Group inbox; the app parses it
Sources/HorizonCore/      storage + sync. Identifiers.swift (bundle/group/container ids), Model/Schema.swift (VersionedSchema V1),
  Store/HorizonStore      @ModelActor: ingest → upsert with field ownership, review queue, manual entry, soft delete, reconciliation; Store/Bin.swift = Recently Deleted (30 days, `wentWith` stamps)
  Coverage/Coverage.swift  M3 gap detection (days silent, cadence gaps, never-ingested platforms, suspicion)
  Strip/Strip.swift        M4 strip logic: mass/heat, pileups (collisions), span, items on a day, levels (weeks/days/items by days across) and cells
  Ingest/ProgressCreep     the reading bar's arithmetic: creeps toward the next mark while the real figure stands still, never backwards
  Sync/ReminderStore      the Reminders side of EventKit (protocol + impl); Sync/CalendarSource = the calendar side, read-only, for the day plan; Sync/Projector = fetch-then-write projector, Reconciler, SyncCoordinator
  Ingest/IngestCoordinator  inbox → parser → store → Reminders
Sources/IngestKit/        documents in → IngestResult out. No storage, no EventKit, no UI.
  Model/Extraction.swift      @Generable schema the model fills per chunk (strings only; dates resolved later)
  Model/IngestResult.swift    public Codable output types
  Normalize/                  file → NormalizedDocument (text pages via PDFKit, or CGImage pages + Vision OCR text for the guards)
  Extract/Chunker.swift       token-budgeted chunking; IngestInstructions.swift = the prompt; Extractor.swift = the only code that talks to a LanguageModelSession (and the OpenAI client, for reading)
  Remote/OpenAIClient.swift   Chat Completions, streamed, strict structured output; classed errors, retries with backoff, an injectable transport; OpenAISchemas = the hand-written strict schemas; PartialJSON = complete elements of a JSON object still being written, ExtractionJSON/PlanJSON decode either route's JSON
  Postprocess/DateResolver    deterministic date resolution (model ISO cross-checked against the copied wording)
  Postprocess/Merger.swift    fold chunk extractions → dedupe, confidence, status, points at stake
  Plan/DayPlanner.swift       M5 day plan: gaps from calendar events, the model proposes, validation keeps it in the gaps, fallback by the numbers
  Eval/Scoring.swift          recall / date / weight / platform accuracy, false positives (all, and those that would ship as .ready)
  Ingestor.swift              public entry point (actor)
Sources/HorizonParse/     `horizon-parse <file> [--pcc|--on-device] [--year] [--term-start] [--verbose]` → JSON on stdout
Tests/IngestKitTests/     deterministic unit tests (no model)
Tests/IngestEvals/        Evaluations-framework run over Evals/Fixtures (calls the model)
Evals/Fixtures/<name>/    source.md (authoring), source.{pdf,png,docx,txt} (rendered), expected.json (ground truth + "render")
Evals/Results/            git-ignored; latest.md is the per-fixture table from the last eval run
Scripts/make-fixtures.swift   re-renders fixture sources from source.md
```

## Commands
```bash
swift build
swift test --filter "IngestKitTests|HorizonCoreTests"    # fast, deterministic (HorizonCore tests use in-memory SwiftData + a fake Reminders store)
HORIZON_EVALS=1 swift test --filter IngestEvals          # model evals, ~1 min per fixture; HORIZON_FIXTURE=<substr> to narrow; HORIZON_PCC=1 for cloud
swift run horizon-parse Evals/Fixtures/01-calc2-pdf/source.pdf --verbose
swift Scripts/make-fixtures.swift                        # after editing any source.md or expected.json "render"
xcodegen generate                                        # after editing project.yml
xcodebuild -project Horizon.xcodeproj -scheme Horizon -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -derivedDataPath .build/DerivedData build
xcrun simctl install booted .build/DerivedData/Build/Products/Debug-iphonesimulator/Horizon.app && xcrun simctl launch booted com.daniel.horizon
xcrun simctl spawn booted log stream --level info --predicate 'subsystem == "com.daniel.horizon"'   # ingest/sync log (os.Logger, category ingest)
xcrun simctl privacy booted grant reminders com.daniel.horizon && xcrun simctl launch booted com.daniel.horizon --ingest-sample   # DEBUG: read the bundled sample without a tap
xcrun simctl launch booted com.daniel.horizon --tab-horizon --zoom-two-weeks   # DEBUG: open on the strip, zoomed to two weeks around today (--zoom-month for a month)
xcrun simctl launch booted com.daniel.horizon --tab-now --plan                 # DEBUG: plan today afresh (the plan streams in; screenshot every 0.4 s to see it); --edit-block opens the first block's editor, --plan-instructions the Tell the Planner sheet
xcrun simctl launch booted com.daniel.horizon --ingest-file /path/to/file      # DEBUG: read any file the simulator can see (broken files, duplicates); --open-documents opens Documents, --delete-first-document bins the first document, --delete-first-course bins the first course
xcrun simctl launch booted com.daniel.horizon --open-recently-deleted          # DEBUG: the bin; --choose-first-deleted opens its Restore / Delete Now dialog; --restore-first-course / --restore-first-document restore without a tap
xcrun simctl launch booted com.daniel.horizon --open-settings                  # DEBUG: Settings; --openai-key <key> stores a key and turns the route on (an invalid key exercises the fallback)
```
The simulator runs a 300M model, not the 3B one; use it to exercise the pipeline, not to judge extraction quality. Settings → Debug → "Ingest Sample Syllabus" (DEBUG builds) feeds `Apps/Horizon/Samples/sample-syllabus.pdf`.

## Rules of the codebase
- The user never types a task (SPEC §2). No composer UI, ever.
- The look is an editorial page (DECISIONS 2026-09-05): every screen sits on `Design.paper` (`.paper()` on lists and forms, and `.onPaper()` on every section or row of a plain list: row modifiers do nothing on the List itself, and a row left out paints a white or black cell over the paper), titles are serif (`Design.installAppearance`, `.deck()`, `.display()`, `.numeral()`), sections get a `Kicker`, rules are hairlines, and `Design.accent` means weight or urgency only. Empty states are `EditorialEmpty`; something in progress is `WorkingLine`. Motion is earned: rows arriving, the level crossfade, the underline sliding, the "now" dot breathing; all of it respects Reduce Motion.
- Every LanguageModelSession lives in `Extractor` (ingest) or `DayPlanner` (the day plan), and so does every use of `OpenAIClient`. Log `response.usage` on every call (it is; see `UsageRecord`).
- OpenAI (`IngestOptions.RoutePolicy.openAI` + `IngestOptions.openAI`) is opt-in with the user's key, behind `FeatureFlags.openAI`; the client retries what can pass (dropouts, rate limits, 5xx) and never what cannot (key, model, request); the ingest falls back to the device on `IngestError.remoteUnavailable` and says so. Network paths are tested with `OpenAITransport` scripts, never the network.
- The day plan is kept for the day only (UserDefaults `dayPlan`, dropped once the day ends); the user's plan instructions (`planInstructions`) persist and go into every plan prompt. The plan by the numbers cannot read them. The plan streams on every route: `DayPlanner.plan(progress:)` reports the complete blocks validated so far (a prefix of the final plan, calendar events included up to the last block), `AppModel.planDraft` keeps block identities across updates, and one `PlanList` shows the draft and then the plan, so rows carry over without re-animating.
- The strip's content follows the zoom: `Strip.level(daysAcross:)` decides weeks / days / items; load is colour (`Strip.heat`), never size.
- Dates: the model emits `dateAsWritten` (copied text) and `dueDate` (ISO). `DateResolver` re-parses the wording; the wording wins on disagreement (a model year slip is forgiven; a model date the document also names means review), except that wording naming several dates without "due" lets the model choose among them. TBD wording rejects a model date outright. A date that neither the wording nor the document mentions is dropped (text pages) or sent to review (image pages). A date printed before the item on a row with a later date is `dateAmbiguous` → review.
- Year: term label, else `IngestOptions.defaultYear` / `--year`, else today. The data detector's own year guess is never used.
- Date-only deadlines are stored at 23:59 local with `dueHasTime == false`.
- Obligations below `IngestOptions.reviewThreshold` (0.7) are `.needsReview`; TBD dates are `.awaitingDate`. Nothing is silently dropped except items unsupported by the document text (counted in `warnings`).
- Prompt or schema changes must be followed by an eval run. Pass = mean recall ≥ 0.9 and zero `.ready` errors (spurious or wrong-dated items that would ship without review); errors that land in review are reported, not fatal.
- Provenance: every obligation carries `sourcePage`; policies carry `verbatim`; same-title-two-dates items carry `conflictingDate`.
- Keep the schema small: it is sent with every chunk on a 4096-token on-device context.
- Storage: SwiftData in the App Group, CloudKit-shaped from V1 (optional/defaulted fields, no unique attributes, optional relationships with inverses). Soft deletes only (`deletedAt`) for obligations, courses and documents. A deleted course or document goes to Recently Deleted (`Bin`, 30 days) with what its deletion took, stamped with the same instant (`Bin.wentWith`), and a restore brings back exactly that: a tombstone the user made before stays deleted. A tombstone that went with its source is `retiredWithSource` and does not capture a re-read item (a user's own deletion does). Erasing (`Delete Now`, or the bin expiring in `expireBin`) is for good: a document is hard-deleted with its file, a course stays an `erasedAt` tombstone until the purge. A binned document shared again is read afresh (revived, queued, its tombstones retired); a document naming a binned or erased course revives it the same way. Never confirm a deletion that lands in the bin; only erasing asks. `HorizonStore` is the only writer; `ReminderProjector` is the only Reminders writer and re-fetches the Horizon list before every write.
- Field ownership: documents own title/due/platform/component unless the field is in `userOverrides`; Reminders owns completion; hand edits (review editor, manual entry, edits made in Reminders) set overrides. A re-ingest that changes an owned field goes back to review with a `changeNote`.
- Manual entry is a fallback reached from the overflow menu, never a primary action; such items carry `origin = manual`.
- Several documents can feed one course: `enqueueDocument(courseID:)` files a document, the coordinator hands the parser `IngestOptions.knownCourse` from `HorizonStore.knownCourse(for:)`, and `assignDocument` files a loose one later. Points at stake are recomputed per course in the store (`PointsAtStake.perItem`, shared with the merger).
- Courses are shown by `displayName` (title, else code) everywhere, including reminder titles. Hand edits to a course (`HorizonStore.updateCourse`) set `Course.userOverrides`, which `upsertCourse` respects. Any obligation can be edited (`ObligationEditor` `.edit`) or deleted (soft delete); both go through the same overrides as review edits.
- The reading route is one choice in Settings (`AppModel.readingRoute`: on device / Private Cloud Compute / OpenAI → `IngestCoordinator.setRoute`); the More menu holds pages and actions only (Documents, Settings, Add Item, Add Course, Edit Courses), and the page pulled down is the sync. PCC needs Apple's managed entitlement `com.apple.developer.private-cloud-compute`; select `Horizon-PCC.entitlements` from Local.xcconfig once granted. Without it `Ingestor.cloudAvailability()` reports the missing entitlement and the row is disabled.
