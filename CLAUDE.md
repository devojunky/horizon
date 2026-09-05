# Horizon

Native iOS 27 / macOS 27 app: an intake engine that turns course documents into obligations and writes them to EventKit. Spec: `SPEC.md`. Deviations and choices: `DECISIONS.md`.

## Layout
```
Package.swift             SwiftPM. Targets: IngestKit (lib), HorizonParse (CLI), IngestKitTests, IngestEvals
Sources/IngestKit/        documents in → IngestResult out. No storage, no EventKit, no UI.
  Model/Extraction.swift      @Generable schema the model fills per chunk (strings only; dates resolved later)
  Model/IngestResult.swift    public Codable output types
  Normalize/                  file → NormalizedDocument (text pages via PDFKit, or CGImage pages + Vision OCR text for the guards)
  Extract/Chunker.swift       token-budgeted chunking; IngestInstructions.swift = the prompt; Extractor.swift = the only code that talks to a LanguageModelSession
  Postprocess/DateResolver    deterministic date resolution (model ISO cross-checked against the copied wording)
  Postprocess/Merger.swift    fold chunk extractions → dedupe, confidence, status, points at stake
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
swift test --filter IngestKitTests                       # fast, deterministic
HORIZON_EVALS=1 swift test --filter IngestEvals          # model evals, ~1 min per fixture; HORIZON_FIXTURE=<substr> to narrow; HORIZON_PCC=1 for cloud
swift run horizon-parse Evals/Fixtures/01-calc2-pdf/source.pdf --verbose
swift Scripts/make-fixtures.swift                        # after editing any source.md or expected.json "render"
```

## Rules of the codebase
- The user never types a task (SPEC §2). No composer UI, ever.
- Every LanguageModelSession lives in `Extractor`. Log `response.usage` on every call (it is; see `UsageRecord`).
- Dates: the model emits `dateAsWritten` (copied text) and `dueDate` (ISO). `DateResolver` re-parses the wording; the wording wins on disagreement (a model year slip is forgiven; a model date the document also names means review), except that wording naming several dates without "due" lets the model choose among them. TBD wording rejects a model date outright. A date that neither the wording nor the document mentions is dropped (text pages) or sent to review (image pages). A date printed before the item on a row with a later date is `dateAmbiguous` → review.
- Year: term label, else `IngestOptions.defaultYear` / `--year`, else today. The data detector's own year guess is never used.
- Date-only deadlines are stored at 23:59 local with `dueHasTime == false`.
- Obligations below `IngestOptions.reviewThreshold` (0.7) are `.needsReview`; TBD dates are `.awaitingDate`. Nothing is silently dropped except items unsupported by the document text (counted in `warnings`).
- Prompt or schema changes must be followed by an eval run. Pass = mean recall ≥ 0.9 and zero `.ready` errors (spurious or wrong-dated items that would ship without review); errors that land in review are reported, not fatal.
- Provenance: every obligation carries `sourcePage`; policies carry `verbatim`; same-title-two-dates items carry `conflictingDate`.
- Keep the schema small: it is sent with every chunk on a 4096-token on-device context.
