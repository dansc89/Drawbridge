# Markup interaction refinement — October 5, 2026

## Corrections

- Line selection follows the actual line segment, excluding empty space inside a diagonal line's annotation bounds. Ellipse selection excludes empty bounding-box corners. Polygon/polyline node and path selection remain unchanged.
- Unchanged geometry, stroke style and polygon fill no longer register undo actions or invalidate annotation summaries. Read-only owned markups cannot be moved or deleted through these entry points.
- Authoring controls restore the actual drawing defaults after leaving a differently styled selection.
- Inline text previews refresh their color and font size to match the committed annotation.
- Cancelling an inline text draft restores the previous unsaved indicator. Existing changes and real style edits made during the draft stay marked as unsaved.
- Inline typing has a separate undo manager, with explicit Undo/Redo responder actions and menu validation. Toolbar actions use the draft history while editing, and return to document history when editing ends. Draft changes refresh presentation without reindexing annotations.

## Verification

Full regression suite with native UI integration and the architectural save corpus: 123 tests executed, 13 optional tests skipped, zero failures. The 100-page app save completed in 1.68 seconds locally; writer corpus checks took 1.68 seconds for the architectural fixture and 0.62 seconds for civil. These timings are local measurements.

New regression cases cover empty-space selection, unchanged geometry/style, read-only move/delete protection, toolbar defaults, inline preview color/font, and isolated text undo/redo returning to markup history on cancellation. Existing all-tool save/flatten/reduce/unflatten checks at four rotations continue passing.

Manual native checks confirmed selecting a line leaves Undo disabled and clicking empty bounding-box space clears selection. Manual text typing exposed a missing Undo responder connection despite programmatic history being present; explicit responder methods were then added and regression checks passed. The final keyboard check was completed in the optimized Interaction Test build: native typing, Command-Z and Shift-Command-Z changed the inline text correctly. Cancelling the draft allowed the clean test document to quit without a discard prompt.

The cancelled-draft unsaved-indicator issue found during manual QA was corrected and covered with clean-document, already-dirty-document and real-style-change cases. No new release is published in this pass.

## Follow-up verification

Saving while the inline editor was active committed the text immediately and returned without a failure alert. Apple Preview opened the resulting PDF and visibly rendered the edited text, rectangles, ellipses, lines, arrows, polylines and filled polygons. An independent MuPDF comparison confirmed only the intended FreeText record changed; all other annotation records matched regardless of ordering. Original page content streams, text, page bounds, rotation, links and rendered pixels with annotations excluded were identical. These checks used disposable fixture copies.

The application save regression now performs three edits and saves through the same controller/document, checks exact annotation records on every reopen, confirms the dirty state clears and bounds file growth. Against the previously failing 100-page architectural fixture, consecutive saves completed in 1.55, 1.41 and 1.30 seconds. The targeted regression passed; the existing full 123-test result remains applicable to the unchanged application code. No crashes occurred in the completed manual follow-up. These are local test results, not a guarantee for every PDF.

## Save performance refinement

Profiling confirmed full-source JSON inspection and full-candidate byte verification dominate save time; appearance generation is small. Exporting encoded streams to individual files was evaluated and rejected because file overhead made saves slower.

The retained optimization reuses the object inspection from the last verified successful save only when the source URL and complete PDF bytes match exactly. Every candidate still receives full graph/encoded-stream verification, markup checks, concurrent-source-change protection and atomic commit. The single cached snapshot expires after 60 seconds and is limited by a 96 MiB combined PDF/JSON size budget; larger files use the ordinary verified path. This removes one full inspection on repeated saves without trusting filesystem timestamps. Annotation generation groups records by page, and verification looks up identifiers directly rather than repeatedly scanning all records.

A regression replaces a successfully saved PDF externally at the same URL with a differently rotated PDF, then saves again and verifies the new geometry/content survive; stale cache reuse would fail this check.

Final full native/corpus regression: 124 tests executed, 13 optional skips, zero failures. The 100-page application saves took 1.41, 1.03 and 1.15 seconds in the final run. A previous full run had one PDFKit thumbnail TIFF mismatch in the combined workflow; the isolated workflow retest and final full suite passed. Independent MuPDF rendering confirmed exact original-content pixels, text and geometry at 0/90/180/270 degrees after repeated save/flatten/reduce/unflatten. No preservation check was weakened to obtain a passing result.

The small synthetic PDF application-save benchmark completed in 0.187, 0.075 and 0.067 seconds. The optimized release build also passed. Measurements are local and depend on PDF size and system load.
