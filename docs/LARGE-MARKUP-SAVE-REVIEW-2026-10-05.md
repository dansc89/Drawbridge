# Large drawing-set markup save review

Reproduction uses private copies of XX.pdf: 124 pages, approximately 155 MB, 17,998 objects and 6,376 streams. The user's original remains untouched.

## Root cause

Small changes previously rebuilt the complete PDF and transported raster streams as large base64 JSON strings. Initial improvements reduced that overhead, but still performed a complete object inspection, graph comparison, file hashing, and regeneration of all existing markup appearances on each save. This imposed a fixed cost based on the entire drawing set even when only six vector annotations changed.

## Final save path

- Inspect object metadata once in the background when the document opens. Retain one bounded inspected file version; the 96 MB budget measures inspection data and new deltas, without repeatedly serializing the entire cache. There is no timer that discards an otherwise valid open-file inspection.
- Identify the source with its device, inode, size, and nanosecond modification/change times. Cache reuse and the authoring session both reject external edits, including same-size edits that restore the old modification date.
- Create an immutable staged snapshot using APFS cloning. When cloning is unavailable, retain a safe copy fallback; those volumes can still incur file-size-dependent I/O.
- Reuse unchanged markup objects and their appearance streams. Generate vector appearances and allocate object IDs only for new or changed markups. Preserve equivalent existing outline and label objects.
- Append a PDF revision to a clone of the snapshot, seeking only to the verified original end offset. The serializer rejects replacement of existing streams.
- Enforce the mutation boundary before writing: original page content, resources, geometry, rotation, catalog page-tree reference, and imported annotations cannot change. Only owned annotations, their page annotation lists, and navigation metadata may be updated.
- Reparse and compare the changed objects and new appearance bytes, rather than inspecting thousands of untouched objects. Original references compare by identity. Confirm the candidate opens through Apple's PDF reader and has the expected page count.
- Recheck the source file version and atomically replace the destination with the validated candidate. Unchanged saves remain no-ops.
- Advance the known source version after a successful snapshot save without clearing any newer unsaved markups. This prevents a later save from mistaking our own completed save for an external modification.

Existing cross-reference streams remain streams in incremental revisions for Apple reader compatibility. Original bytes stay intact through staged cloning and append-only writing; regression tests independently compare complete original byte prefixes. Original content is neither rasterized nor redrawn. Old incremental revisions remain in the PDF; this path does not compact them during ordinary markup saves.

## Validation

- Full regression suite: 135 tests, 15 optional tests skipped, zero failures. Coverage includes all seven markup kinds, rotated/cropped pages, Unicode text, links, imported annotations, deletion, flatten/reduce/unflatten, external changes, and repeated saving.
- On the 155 MB set, the earlier whole-file path took 8.05, 7.48, and 7.21 seconds. The initial incremental implementation still took 2.23, 1.74, and 1.68 seconds.
- The change-specific path, with inspection prepared during opening, passes a strict one-second application save-completion assertion for six new markups per pass. Final production measurements are 0.56, 0.54, and 0.47 seconds. A separate prepared run measured 0.53, 0.50, and 0.51 seconds.
- Without preparation, initial inspection of this large set took the first save to 1.36 seconds; subsequent saves were approximately 0.48 seconds. If the user saves before background preparation finishes or after external changes invalidate it, this initial inspection is still required.
- Six new markups with 200 existing text markups saved in approximately 0.17 seconds on a small fixture. The test verifies the old appearances remain intact, the revision adds under 20 KB, and unchanged annotations allocate no new object IDs.
- Independent MuPDF comparison: the original bytes remain an exact prefix; all 124 raw page content streams, page boxes and rotations remain identical. Original-content pixels match on pages 1, 61 and 124 with annotations excluded. Eighteen additions across three saves add approximately 20.5 KB. qpdf reports no syntax or stream encoding errors.
- Added mutation-boundary tests reject changes to original page contents/resources/rotation/boxes and imported annotations. Cache tests cover atomic external replacement and same-size in-place editing with restored mtime.
- The production benchmark exercises the application view controller and PDF view, including save completion and dirty-state cleanup. The earlier incremental output was also visually verified in Apple Preview. This does not certify every file-provider or network-volume latency.
- Packaged UI smoke test: the first prepared test bundle rejected a save on an existing 18-annotation fixture. After explicitly rebuilding the production executable and repackaging, toolbar and keyboard rectangle saves both succeeded; writer/verification/commit times were 0.083 and 0.081 seconds, and qpdf accepted the saved file. The same fixture also passed three application save-completion tests in 0.153, 0.055 and 0.056 seconds. The initial bundle failure was not independently isolated to a specific guard, so the successful rebuild is recorded rather than attributing it to a proven cause.

The installed application has not been replaced and no public GitHub release was issued during this review.
