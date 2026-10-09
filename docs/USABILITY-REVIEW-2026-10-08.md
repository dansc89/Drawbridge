# Usability review — October 8, 2026

Reviewed release 6.0 build 161 and patched the development branch.

## Reproduced and fixed

- Rectangle edge selection rejected points just outside its geometric bounds, including floating-point coordinate rounding at a corner. Apply the existing stroke/click tolerance to bounds-based markup selection.
- A queued Markups List refresh restored an older selection after the user selected a row. New list selections supersede the pending refresh.
- Switching drawing tools or pressing Escape cleared the controller selection but left the list selection and orange overlay. Clear both immediately and replace the queued selection restoration.
- Free-text vector appearances ignored page rotation. Text appeared horizontal while editing, but sideways after saving and reopening in Apple Preview. Capture page rotation, rotate the saved glyph appearance, and write standard FreeText rotation metadata. Other page content and imported markup appearances remain unchanged.

## Verification

Final full suite: 195 tests, 23 optional skips, zero failures. Includes four new regression tests for edge tolerance, delayed list selection, tool/Escape deselection, and saved text pixel orientation at 0/90/180/270 degrees.

Large-set production save completion measurements, using disposable local copies:

| PDF | Pages | New markups per save | Save seconds |
| --- | ---: | --- | --- |
| Plumbing | 21 | 6 / 100 / 6 | 0.807 / 0.721 / 0.696 |
| Expo fire | 99 | 6 / 100 / 6 | 0.377 / 0.458 / 0.285 |
| Mechanical | 14 | 6 / 100 / 6 | 0.478 / 0.551 / 0.457 |

Every save reopened with expected markup records, unchanged page geometry/rotation, and the original PDF bytes preserved as a prefix. Original fixtures were not modified. Measurements include save completion, not just background writer execution; they apply to these local files and this Mac.

Manual app pass exercised keyboard tool activation, two-click line/arrow placement, rectangle/ellipse dragging, pen, polygon/polyline completion, text editing/commit, and repeated Save on a disposable plumbing PDF. Opened the saved file in Apple Preview: vectors persisted; this inspection exposed the rotated-text bug. Subsequently confirmed corrected multiline Unicode text remains horizontal in Preview on the 90-degree fixture. Also visually checked tool switching and Escape/click-away selection in the patched app.

## Limits and remaining review targets

This pass does not establish zero defects or guaranteed production readiness. The 69-page Architectural file formerly in Downloads is no longer at that path; this pass used the three retained local fixture sets. Optional corpus/OCR checks skipped without their environment fixtures are identified in the test log. The previous 69-sheet OCR target verification is separate evidence, not a new run in this review.

Further review should cover cancellation responsiveness during complex OCR pages, early progress estimates, additional scanned/raster drawing sets, and other viewers' editing behavior after importing rotated text. No release tag or published assets were replaced during this review.

Local evidence: tmp/usability-complete-tests.log, tmp/usability-large-save/results.json, tmp/text-orientation-repro.log, and tmp/text-rotation-preview-fixtures.log.
