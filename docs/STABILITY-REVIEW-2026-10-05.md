# Stability review — October 5, 2026

This pass builds on the annotation-save correction in `20c58ff`. Customer PDFs remain private local fixtures.

## Corrections

- Block closing or replacing the current document while saving or processing it. Previously the discard/save prompt checked only flatten/reduce operations and could run during a background markup save.
- Only reopen a reduced PDF if the same document is still active and has no new edits, matching the flatten workflow.
- Separate inline text draft notifications from PDF annotation mutations. Typing keeps the unsaved indicator current, but no longer invalidates the annotation index and rescans the entire drawing set on every keystroke. Commit still updates the PDF and summary normally.

## Verification

- Full suite: 117 tests, nine optional tests skipped, zero failures. Native menu integration and the architectural save corpus were enabled.
- Additional real-file checks: civil reference bounds via Vision and Mechanical mixed-rotation sheet zones, both passed.
- All seven markup tools (rectangle, ellipse, line, arrow, polygon, polyline, text) survived annotation-only save, flatten in place, lossless reduction, unflatten and three subsequent saves at 0/90/180/270 degrees, including nonzero crop origins.
- Recovery retained the exact seven markup records. Original text, media/crop boxes, rotations, link and imported annotation remained unchanged. Removing the test markups produced matching base-page rendered pixels. Source fixture bytes remained unchanged.
- Save completion on the 100-page architectural fixture: 1.37 seconds. Background save on the small fixture: 0.052 seconds. These are local measurements, not a universal latency guarantee.
- Fifty text changes produced fifty draft notifications, no annotation reindex notifications, and one committed annotation update with the final text.
- Independent MuPDF rendering displayed all saved annotation types and preserved the link across all four rotations.

## Remaining validation limits

The full suite does not enable every historical optional OCR/reduction/search corpus. Native computer-control intermittently failed with `noWindowsAvailable` when sending input to Preview; an existing architectural rectangle output could be visually inspected, but this pass did not complete manual entry of every tool and reopening that output in Preview. Programmatic interaction and independent rendering must not be described as complete manual UI certification.

The latest available Drawbridge crash report is the previously investigated 4.3 PDFKit form-filling-queue crash. The inherited PDFView.document getter and its background-read regression check remain in place. No crash occurred in this test run; this does not rule out unreported interactive crashes.

An ad-hoc signed local stability test build is prepared separately from the installed/public application. This pass does not publish or notarize a new release.
