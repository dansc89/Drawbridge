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

Manual native checks confirmed selecting a line leaves Undo disabled and clicking empty bounding-box space clears selection. Manual text typing exposed a missing Undo responder connection despite programmatic history being present; explicit responder methods were then added and regression checks passed. Repeating the final keyboard check was interrupted by repeated desktop-control timeouts. The QA process remained alive; its sampled main thread was idle in the AppKit event loop, and no new Drawbridge crash report appeared. The final text keyboard check remains unverified manually.

The cancelled-draft unsaved-indicator issue found during manual QA was corrected and covered with clean-document, already-dirty-document and real-style-change cases. No new release is published in this pass.
