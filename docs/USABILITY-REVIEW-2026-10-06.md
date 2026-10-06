# Usability and performance review — October 6, 2026

## Change

The PDF Contents sidebar previously invalidated its entire annotation summary on every markup mutation. Adding, editing, or deleting one annotation then enumerated annotations across every sheet. This work runs on the main thread and grows with consultant annotations already in the set.

Cache counts, type totals, and up to three CAD-text samples per page. Invalidate only the edited page; retain full invalidation when the document changes, page count changes, or a bulk invalidation is requested. The cache holds values rather than PDF pages or annotation objects. No PDF-writing behavior changes.

## Verification

- An 80-page fixture with 8,000 annotations verifies that a one-page edit enumerates that page exactly once and reads no annotations on the other 79 pages. An unchanged summary reads no pages. Bulk invalidation scans all pages again.
- Summary classification updates correctly after hidden/print flags change, deletion, page insertion, and switching documents.
- Debug timings: full recount 27.1 ms; recount after one-page edit 0.423 ms. These measure sidebar recount work, not total interaction latency.
- Production application save-completion test on a disposable copy of XX.pdf (124 pages, approximately 155 MiB), after preparing its inspection on open: six new rectangles per save, three consecutive saves, 0.605 / 0.500 / 0.465 seconds. Every saved document is reopened, compared against the expected markup records, and checked for bounded file growth. The user’s original file is not modified.
- Full automated suite: 137 tests, 15 optional/environment-dependent skips, zero failures on the final run. Coverage includes tool shortcuts and highlighting, two-click line/arrow authoring, inline text undo, polygon/polyline geometry, page/history navigation, invert isolation, search cancellation, flatten/reduce/unflatten, and saving at all four rotations.

## Limits and follow-up

The first full run failed two exact TIFF comparisons in the existing original-content rendering checks. Both passed in isolation and in the subsequent full run, without changing their tests or PDF-writing code. The initial TIFF sizes differed by 3,544 bytes. The cause is not established; retain this as an intermittent visual-test investigation rather than claim it is fixed.

This pass uses automated controller and production save tests. It does not claim a fresh manual Apple Preview or packaged-app UI verification. These changes are not yet included in a new published release; v5.0 remains the published build.
