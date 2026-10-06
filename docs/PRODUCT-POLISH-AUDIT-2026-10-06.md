# Drawbridge product and performance audit

October 6, 2026. This is a source-backed review with automated interaction tests, not a claim of a complete manual certification of every workflow.

## Addressed in this pass

1. Save collection enumerated every page’s annotations twice. Capture now repairs duplicate owned-markup identities and collects records in one pass. An 80-page, 8,080-annotation test verifies one annotation read per page, stable unique identities, and preservation of imported annotations.
2. Pointer preview movement refreshed every markup toolbar control. Line/arrow/polyline/polygon hovering and shape dragging now update geometry without rebuilding toolbar presentation. Tests exercise 100 pointer events per tool and verify no presentation callbacks, followed by presentation updates on commit.
3. A queued explicit Save depended on the sidecar-autosave queue being populated. Vector markup intentionally skips that queue, so a queued request could remain stranded. Drain explicit requests after every completed manual save; skip the redundant write when there are no later edits. A regression test adds an edit after the first snapshot and verifies both annotations on disk after the queued save.
4. Optional performance logs now report total application save time plus capture, writing, replacement, markup count, and file-provider routing. This distinguishes local incremental-write performance from cloud-folder replacement delays. Diagnostics remain disabled unless DRAWBRIDGE_PERF=1.

These changes retain the existing annotation-only writer and its original-content verification boundary.

Final verification: 140 automated tests, 15 optional/environment-dependent skips, zero failures. The production application save-completion test on a disposable copy of XX.pdf (124 pages, approximately 155 MiB) added six new markups per pass and completed in 0.536 / 0.574 / 0.473 seconds. Diagnostics measured capture at 0.18–0.28 ms, writing at 451–554 ms, and total save at 472–573 ms. The test reopens each saved file and compares its markup records; the original user file is unchanged. This is local storage after inspection preparation, not a cloud-provider or cold-first-save certification. No new release is published by this pass.

## Priorities for a credible architecture-focused PDF app

| Priority | Observed limitation | Recommended work and acceptance check |
| --- | --- | --- |
| P0 | Local large-file saves are benchmarked, but genuine Google Drive/iCloud file-provider saves are not certified. Persistence stages locally and then replaces the whole destination file. | Benchmark the actual provider using disposable drawing sets, including cold open, immediate first edit/save, repeated saves, and external file changes. Report whole-command latency and verify disk contents. Do not promise provider performance from a local-folder test. |
| P0 | Two original-content TIFF comparisons failed intermittently in the preceding review, then passed unchanged. Cause remains unproven. | Capture failing image pairs and compare decoded pixels and metadata separately. Retain original stream/box/rotation verification. Resolve the cause before treating the visual suite as consistently reliable. |
| P1 | File menu has no Print command and the source has no print-operation implementation. | Add native printing with page ranges, paper size, scale, and current-sheet selection; verify vector output and unchanged saved PDFs. |
| P1 | Annotation toolbar has five stroke colors, fixed widths/font sizes, and a polygon fill popup. No coherent general properties inspector. | Add a compact selection-aware inspector: custom color, opacity, stroke/fill, font family, size, and alignment. Keep defaults separate from existing selection properties. Test persisted appearance in independent viewers. |
| P1 | Text highlight/underline/strikeout remain compatibility no-ops; only the new basic shape/text authoring path is implemented. | Implement text markup through the verified annotation writer, with per-line quads, rotated-page tests, undo, and independent rendering checks. Add callouts, revision clouds, and freehand next. Do not expose unfinished controls. |
| P1 | Authoring recognizes only Drawbridge-owned annotations. Imported consultant markup cannot be edited through this path. | Add explicit support by subtype, preserving unsupported annotations. Include imported appearances and standard annotation metadata in compatibility tests before allowing edits. |
| P1 | Document cycling calls openDocument again, reloading the file; it does not retain a live per-tab document/view session. | Retain document, page/zoom/scroll, search, undo, and save state per tab with a bounded memory policy. Test rapid switching and pending saves without lost edits. |
| P2 | Old markup editing/reordering entry points are no-ops; Paste outside text editing does nothing. | Replace obsolete paths with tested commands for the new authoring model: duplicate, copy/paste, multi-selection, alignment, and ordering. Remove unreachable legacy code only after callers/tests are migrated. |
| P2 | Legacy measurement/takeoff selectors are hidden; scale bookkeeping does not constitute a completed takeoff workflow. | Implement calibration, distance, poly-length, area, perimeter, and count with real units and per-sheet scale. Validate known plan dimensions and exported totals. |
| P2 | Search targets the current PDF’s text; no set-wide or markup-comment search is implemented in that path. | Add tab/set and comment search with cancellation, streaming results, and unambiguous sheet labels. Keep typing and navigation responsive. |
| P2 | No reusable markup preset/tool-chest workflow in the new toolbar. | Add saved tool presets after properties stabilize; preserve properties, shortcuts, and optional comment text without duplicating document content. |

## External reference points

Bluebeam documents reusable tools, markup review, and measurements as core workflows: [Quick Start](https://support.bluebeam.com/revu/resources/revu-21-starter-kit.html), [Tool Chest](https://support.bluebeam.com/user-manual/menus/window/tool-chest-panel.html), [Measurement tool](https://support.bluebeam.com/user-manual/menus/tools/measure-tool.html).

PDF Expert documents annotation/comment workflows and multi-PDF search: [Annotation tools](https://pdfexpert.com/features/pdf-annotate-mac), [Feature overview](https://pdfexpert.com/features). These establish workflow expectations; they do not establish either competitor’s save implementation or performance.

## Sequence

Finish save/compatibility certification first. Then native printing, annotation properties, missing text markups, and retained tab sessions. Expand architectural markup and takeoff tools only when each subtype has round-trip save, undo, rotation, and independent-viewer checks. Keep a representative drawing corpus and measure cold/warm open, pointer interaction, search cancellation, and end-to-end saves for every release candidate.
