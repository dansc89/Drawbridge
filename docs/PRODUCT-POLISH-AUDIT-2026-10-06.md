# Drawbridge product and performance audit

October 6, 2026. This is a source-backed review with automated interaction tests, not a claim of a complete manual certification of every workflow.

## Addressed in v5.1

1. Save collection enumerated every page’s annotations twice. Capture now repairs duplicate owned-markup identities and collects records in one pass. An 80-page, 8,080-annotation test verifies one annotation read per page, stable unique identities, and preservation of imported annotations.
2. Pointer preview movement refreshed every markup toolbar control. Line/arrow/polyline/polygon hovering and shape dragging now update geometry without rebuilding toolbar presentation. Tests exercise 100 pointer events per tool and verify no presentation callbacks, followed by presentation updates on commit.
3. A queued explicit Save depended on the sidecar-autosave queue being populated. Vector markup intentionally skips that queue, so a queued request could remain stranded. Drain explicit requests after every completed manual save; skip the redundant write when there are no later edits. A regression test adds an edit after the first snapshot and verifies both annotations on disk after the queued save.
4. Optional performance logs now report total application save time plus capture, writing, replacement, markup count, and file-provider routing. This distinguishes local incremental-write performance from cloud-folder replacement delays. Diagnostics remain disabled unless DRAWBRIDGE_PERF=1.

These changes retain the existing annotation-only writer and its original-content verification boundary.

Final verification: 140 automated tests, 15 optional/environment-dependent skips, zero failures. The production application save-completion test on a disposable copy of XX.pdf (124 pages, approximately 155 MiB) added six new markups per pass and completed in 0.536 / 0.574 / 0.473 seconds. Diagnostics measured capture at 0.18–0.28 ms, writing at 451–554 ms, and total save at 472–573 ms. The test reopens each saved file and compares its markup records; the original user file is unchanged. The follow-up also measured actual Google Drive saves on a disposable copy: 1.107 / 0.489 / 0.462 seconds, without changing the user's original. The provider save staging defect was fixed before publishing signed and notarized v5.1.

## Current polish pass (not released)

- Added native macOS Print (Cmd+P) and Print Current Sheet, including page ranges, paper size, orientation, scaling, and preview. Jobs default to actual size without automatic rotation. A print-to-PDF test verifies a single selected sheet, unsaved annotation appearance, vector paths rather than page rasterization, and original colors while the viewer is inverted. Job construction preserves the source page reference, annotations, boxes, and rotation and leaves shared print settings untouched.
- Corrected obsolete Quick Start, About, README, and user-manual descriptions that omitted current markup capabilities. Documented tool shortcuts, two-click lines/arrows, inline text, and imported-annotation editing limits.
- An initial full run exposed one intermittent exact-pixel mismatch in a thumbnail-based comparison after removing a text annotation. Twelve isolated repetitions and the next full run passed unchanged; the cause is not proven. Those preservation checks now render current PDFPage state directly into a fresh explicit sRGB context, retaining exact pixel comparisons without depending on thumbnail caches or implicit image profiles. This changes test rendering only, not PDF persistence.

Verification: the final full suite passed 143 tests with 15 environment-dependent skips and zero failures. The production six-markup save benchmark on the 124-page XX.pdf copy completed in 0.613 / 0.532 / 0.502 seconds and reopened each result successfully. This pass is local and not included in public v5.1. Physical printer testing remains outstanding.

## Priorities for a credible architecture-focused PDF app

| Priority | Observed limitation | Recommended work and acceptance check |
| --- | --- | --- |
| P1 | Native printing has automated print-to-PDF coverage; physical printer behavior is not certified. | Test architectural sheet sizes, mixed rotations, printer margins, and scaling using real printers before claiming comprehensive printing compatibility. |
| P1 | The local properties inspector now supports custom opaque colors, line weights, text sizes, and polygon fill. | Add opacity, font family, and alignment only with persisted appearance and independent-viewer checks. |
| P1 | Text highlight/underline/strikeout remain compatibility no-ops; only the new basic shape/text authoring path is implemented. | Implement text markup through the verified annotation writer, with per-line quads, rotated-page tests, undo, and independent rendering checks. Add callouts, revision clouds, and freehand next. Do not expose unfinished controls. |
| P1 | Authoring recognizes only Drawbridge-owned annotations. Imported consultant markup cannot be edited through this path. | Add explicit support by subtype, preserving unsupported annotations. Include imported appearances and standard annotation metadata in compatibility tests before allowing edits. |
| P1 | The local tab pass preserves viewing state and reuses clean documents with a bounded cache. Dirty sessions still use Save/Discard/Cancel; Undo stacks reset on switching. | Retain independent dirty sessions and Undo stacks per tab, with save ownership and memory-pressure eviction tests before removing prompts. |
| P2 | Old markup editing/reordering entry points are no-ops; Paste outside text editing does nothing. | Replace obsolete paths with tested commands for the new authoring model: duplicate, copy/paste, multi-selection, alignment, and ordering. Remove unreachable legacy code only after callers/tests are migrated. |
| P2 | Legacy measurement/takeoff selectors are hidden; scale bookkeeping does not constitute a completed takeoff workflow. | Implement calibration, distance, poly-length, area, perimeter, and count with real units and per-sheet scale. Validate known plan dimensions and exported totals. |
| P2 | Search targets the current PDF’s text; no set-wide or markup-comment search is implemented in that path. | Add tab/set and comment search with cancellation, streaming results, and unambiguous sheet labels. Keep typing and navigation responsive. |
| P2 | No reusable markup preset/tool-chest workflow in the new toolbar. | Add saved tool presets after properties stabilize; preserve properties, shortcuts, and optional comment text without duplicating document content. |

## External reference points

Bluebeam documents reusable tools, markup review, and measurements as core workflows: [Quick Start](https://support.bluebeam.com/revu/resources/revu-21-starter-kit.html), [Tool Chest](https://support.bluebeam.com/user-manual/menus/window/tool-chest-panel.html), [Measurement tool](https://support.bluebeam.com/user-manual/menus/tools/measure-tool.html).

PDF Expert documents annotation/comment workflows and multi-PDF search: [Annotation tools](https://pdfexpert.com/features/pdf-annotate-mac), [Feature overview](https://pdfexpert.com/features). These establish workflow expectations; they do not establish either competitor’s save implementation or performance.

## Sequence

Continue save/compatibility regression checks. Next priorities are annotation properties, missing text markups, and retained tab sessions. Expand architectural markup and takeoff tools only when each subtype has round-trip save, undo, rotation, and independent-viewer checks. Keep a representative drawing corpus and measure cold/warm open, pointer interaction, search cancellation, and end-to-end saves for every release candidate.

## Annotation properties and tab follow-up (local, not released)

Added a nonmodal properties popover with custom opaque stroke/text color, precise line weight (0.25–12 pt), text size (6–144 pt), and polygon fill. Changes to an existing annotation no longer change drawing defaults. Custom values display accurately in the toolbar. PDFKit truncates fractional font sizes when setting or reopening fonts; the authoring path now retains the exact value in standard /DA plus an owned annotation metadata field, which the verified writer preserves. Round-trip tests cover custom colors, width, fractional font size, Undo/Redo, and exact original-byte prefixes.

Tab order is stable. Page/zoom, navigation history, and search query are remembered per URL. The cache retains at most two inactive clean documents and at most 256 MiB of source-file sizes (not a claim of a hard decoded-memory bound). File identity/timestamps are checked before reuse; externally changed, discarded, oversized, and evicted documents reload. A clean document's polygon adaptation is reused rather than rescanning every annotation on each bind. Cached-tab save tests reopen the result and verify original bytes and expected annotations.

This does not implement dirty-document retention or independent per-tab Undo stacks. Those remain separate lifecycle work rather than silently retaining discarded edits.

Verification: the full suite passed 151 tests with 16 optional/environment-dependent skips and zero failures. The final production run passed the properties and real-drawing tab/save checks. On the disposable 124-page, approximately 155 MiB drawing fixture, cold open took 0.372 seconds and cached return took 0.011 seconds after removing the redundant first-page fit. Six-new-markup saves completed in 0.555 / 0.528 / 0.501 seconds; each output reopened with matching annotation records. Tests also verify source-byte preservation, external replacement, discarded edits, cache eviction, stable tab cycling, and saving after a cached switch. This pass has automated AppKit/PDFKit coverage; it has not received fresh manual Apple Preview or physical-printer verification and is not published.
