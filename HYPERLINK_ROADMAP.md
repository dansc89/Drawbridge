# Hyperlink reliability roadmap

## Goal

Every confirmed sheet reference receives a verified link to the correct sheet. A run must never report complete coverage while known references remain unresolved. Unreadable content, duplicate sheet numbers, or references to missing sheets must produce explicit review items rather than guessed links.

This is a roadmap, not a statement that the current release already meets every requirement. No detector can prove that arbitrary unreadable pixels contain no references; coverage reporting must distinguish verified text from content that still requires review.

## 1. Establish a reproducible coverage baseline

- Build a local regression corpus of representative architectural, structural, plumbing, mechanical, electrical, and civil sets. Keep private project PDFs out of the public repository.
- Independently inventory sheet numbers and reference locations: sheet indexes, detail bubbles, section references, notes, rotated labels, and repeated references.
- Include encoded CAD fonts, scanned pages, mixed text/image pages, narrow index columns, large sets, and duplicate or missing sheet identifiers.
- Measure reference recall, incorrect destinations, incorrect activation rectangles, processing time, and memory. Test the saved output, not just the in-memory annotations.

Acceptance: all known references in each supported fixture have correctly positioned links and correct destinations; zero incorrect destinations. Unsupported cases are documented review items.

## 2. Recover text and geometry together

- Prefer literal PDF text and glyph coordinates over recognizing the same content again from rendered pixels.
- Recover CAD font encodings while keeping character positions tied to the original drawing. Verify transforms, rotation, and page boxes before using coordinates.
- Maintain a reference ledger containing the page, literal token, location, detection method, destination, and verification status.
- Add a focused visual check when recovered geometry is unreliable. Keep OCR-confusion handling constrained to confirmed nearby literals.

Acceptance: the plumbing index and encoded-font fixtures achieve full coverage without OCR substitutions deciding destinations. Source page content, fonts, images, and graphics remain unchanged.

## 3. Add targeted fallback and reconciliation

- Compare expected references from the ledger with links actually created; retry only uncovered regions at suitable resolutions and orientations.
- Detect references on mixed pages even when other selectable text exists. The presence of unrelated text must not suppress OCR for image-only callouts.
- Reconcile sheet-index entries, title-block identities, and destination pages. Surface duplicate identifiers, absent destinations, and conflicting readings.
- Deduplicate overlapping detections while preserving separate occurrences of the same reference.

Acceptance: supported fixtures have no unresolved expected references, no duplicate link overlays, and no cross-sheet misrouting. Retry work scales with missing regions rather than repeatedly rasterizing entire sets.

## 4. Make incomplete coverage visible and recoverable

- Report linked references, unresolved references, and regions not verified. Never describe a run with unresolved items as fully complete.
- Provide a review list that jumps to each issue, shows its detected token and proposed destination, and allows correction or explicit exclusion.
- Allow retrying a page or region without rerunning the entire set. Retain corrections for the current document.
- Keep the ordinary successful workflow short; show detailed diagnostics when there are gaps.

Acceptance: deliberate failures appear in the review list; users can resolve them without rebuilding the set, and completion status reflects remaining issues accurately.

## 5. Enforce saved-file and release gates

- Reopen saved PDFs and verify every generated link's destination and activation rectangle against the ledger.
- Preserve original page streams, graphics, annotations, rotation, page labels, and bookmarks. Saving links must not flatten or rasterize pages.
- Test navigation in Drawbridge and independent viewers, including Apple Preview and PDF Expert when available.
- Gate releases on the complete fixture inventory, deterministic detection tests, preservation checks, and representative performance measurements.

Acceptance: no silently missed known references, no incorrect targets, no content changes, and no unexplained performance regression in the supported corpus. Record residual limitations in release notes.

## Implementation order

Begin with the coverage baseline and reference ledger, then improve text-coordinate recovery. Add targeted retries and the review interface against that measurable baseline. Finish by making saved-file verification a release gate. Expand the corpus whenever a user reports a new failure.
