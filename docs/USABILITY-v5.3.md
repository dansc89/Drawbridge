# v5.3 release validation — October 6, 2026

## Found and resolved

The signed package rejected a one-rectangle save although the release regression suite passed. Opening through the macOS file dialog changed ctime (access metadata) without changing size, inode, mtime, or PDF bytes. The exact stamp comparison incorrectly classified this as an external PDF edit.

Markup sessions now capture a frozen APFS source clone. A ctime-only discrepancy requires a byte-for-byte comparison against that baseline and a stable current stamp. Actual content changes still reject saving. Exact comparisons during snapshotting and before replacement remain in force. Clones share unchanged APFS storage; ordinary saves do not compare all source bytes. Failure phases are recorded in the system log without file paths or contents.

The inspector also required Return to apply numeric changes. End-of-editing now sends the same action when tabbing out or leaving the field.

## Validation

- Production regression suite: 157 tests, 14 optional fixture tests skipped, zero failures on the final production run.
- Signed app: all eight toolbar markup types created by their keyboard shortcuts. Two-click line/arrow creation, polygon fill, inline multiline text, exact font size, Undo/Redo, repeated saves and original-byte preservation verified.
- Apple Preview: manually reopened the UI-saved PDF; all eight markup types visible, original text, blue graphic, and imported black rectangle unchanged.
- Structural verification: qpdf reports no syntax/stream errors. Saved annotation subtypes: Square, Circle, two Line, Polygon, two Ink, FreeText. Text-size metadata retained 19.25 points.
- Combined automated workflow: all tools at 0/90/180/270 rotations, navigation, flatten/reduce/unflatten, repeat saves, imported annotation preservation, queued-save safeguards, and cache invalidation.
- Final production benchmark: 124 pages / 155 MiB, application save completion 0.575 / 0.550 / 0.494 seconds, six new markups with 200 existing text annotations 0.166 seconds. Timings vary with hardware and filesystem.

Release assets require Apple notarization and downloaded-artifact validation before publication. No private drawing fixtures are included in Git commits or release assets.
