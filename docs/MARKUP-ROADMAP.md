# Drawbridge markup roadmap

Status: rectangle, ellipse, line, arrow, polyline, and text box foundation implemented in a separate local trial based on v4.2. Select, draw, move, resize, stroke color/weight, delete, undo/redo, and verified annotation-only saving are available. Typewriter, notes/callouts, ink, and measurement tools remain planned. Development proceeds through separate local test builds; publishing requires explicit user approval.

## Product target

Build a full architectural review markup workflow comparable to Bluebeam Revu, in stages. The user wants the markup controls in the center/top area of the window, separate from the existing left-side document operations (open, OCR bookmarks, hyperlinks, flatten, reduce, sheet lookup, page fit).

Reference inventory: [Bluebeam Tools menu](https://support.bluebeam.com/online-help/revu20/Content/RevuHelp/Menus/Tools/Tools-Menu.htm). This is a baseline inventory, not a claim of complete parity with every Revu edition, proprietary metadata format, or collaboration service. Maintain a feature checklist as individual tool specifications are implemented.

## Interface

- Retain the existing document-operation group on the left.
- Add a distinct Markup group in the highlighted center area. Select, Rectangle, Ellipse, Line, Arrow, Polyline, and Text Box are implemented; add further controls only when they work.
- Grow through compact dropdown groups: Text, Shapes, Pen, Highlight, Stamps/Images, Measure. Show active tool with a strong selected background and its name; Escape returns to Select.
- Put context-dependent properties in a second row shown during markup use: stroke/fill color, opacity, line weight/style, endpoints, font/size/alignment, and measurement scale where relevant.
- Add an optional right-side Properties panel and lower Markups List. Keep maximum drawing space when these panels are closed.
- Support toolbar overflow and narrow windows. Tooltips, keyboard shortcuts, accessibility names, disabled states, and visible selection handles are part of each completed tool.
- Choose shortcuts without breaking existing sheet/navigation commands; typing in text fields must never trigger drawing tools.

## Phase 0 — prove the annotation foundation

First milestone: one rectangle can be created, selected, moved, resized, styled, deleted, undone/redone, saved, closed, and reopened correctly.

Create an isolated annotation model, interaction controller, appearance renderer, and persistence adapter. Audit old markup code; reuse only pieces with verified behavior, not the previous authoring path wholesale. Keep PDFKit display/navigation separate from annotation authoring.

Store geometry in native PDF page coordinates, with one tested conversion boundary for screen coordinates, crop origins, and page rotation. Annotation rotation changes annotation geometry only. Draft previews stay in a UI overlay until committed. Use stable IDs and transaction-based undo; a drag is one undo operation.

Prototype annotation-only persistence before expanding tools. Write new/revised annotation dictionaries and appearance streams without redrawing pages. Retain untouched annotation objects, links, forms, resources, and document metadata. Choose incremental updates or object-preserving rewriting based on compatibility and measured size/performance; do not assume either approach is safe without evidence. No full-page render/export fallback when an annotation save fails.

Write to a temporary candidate, validate it, then commit atomically. Keep the document dirty and edits recoverable on failure. Save finishes only after the committed file contains the changes. Detect external changes and unsupported/encrypted/signed inputs explicitly instead of overwriting silently. Signed PDF support requires a separate specification because modifications can invalidate existing signatures.

## Phase 1 — everyday architectural review

- Shapes: rectangle, ellipse, line, arrow.
- Text: text box, typewriter-style text, sticky note, callout.
- Drawing: pen and freehand highlighter; eraser limited to supported ink/highlight annotations.
- Shared editing: multi-select, bulk delete, copy/paste, duplicate, move/resize, grouping where compatible, lock/unlock, undo/redo, default styles, repeat-tool mode.

Each tool must have a portable saved appearance so it displays without Drawbridge-specific rendering. Text requires verified font handling, layout, and appearance generation. Build callouts only after text and line editing are reliable.

## Phase 2 — richer drawing and text review

- Polygon, polyline, arc, revision cloud, cloud with callout, dimension/leader markup.
- Text highlighting, underline, strikeout, squiggly underline, and review-text comments, without changing underlying text.
- Alignment, distribution, snapping, constrained drawing, ordering and annotation-only rotation.
- Searchable Markups List with author, subject, comments, timestamps, status, page, selection synchronization, and bulk property editing.

Text selection markup needs rotated text/quadrilateral tests. CAD geometry text may not support text selection; freehand highlighting remains available.

## Phase 3 — reusable review tools

- Image annotations, image crop, stamps, custom static stamps, visual signature stamps, flags, file attachments, and saved tool presets/tool chest.
- Markup import/export and summaries, with explicit supported formats.
- Reusable architectural review sets; flatten/unflatten interoperability for newly authored annotations.

A visual signature stamp is distinct from a cryptographic digital signature. Dynamic stamps and proprietary Bluebeam tool-set compatibility need separate feasibility tests.

## Phase 4 — architectural measurement and takeoff

- Per-page calibration, units, precision, and multiple calibrated regions when required.
- Length, polylength, area, perimeter, angle, diameter, radius, count, volume and cutouts.
- Sketch-to-scale tools and quantity summaries.
- Dynamic Fill as a separate research milestone after measurement geometry is proven.

Measurements must use PDF coordinates and calibration, never screen pixels. Validate mixed page sizes/rotations and known reference geometry. Do not imply measurement accuracy until tolerances are documented and tested. Cross-app measurement semantics may require metadata beyond standard visual PDF annotations.

## Phase 5 — parity review

Compare the implemented checklist against the Bluebeam review workflow with the user. Resolve missing behaviors and compatibility gaps. Studio-style live collaboration, PDF content editing, redaction, form authoring, and cryptographic signing are separate projects; they must not be silently conflated with non-destructive markup.

## Required gate for every milestone

1. Test placement/editing at multiple zooms, all four rotations, nonzero crop/media origins, mixed sizes, portrait/landscape sheets, and very large drawings.
2. Save/reopen in Drawbridge, Apple Preview, PDF Expert, and Bluebeam where available. Verify appearance, editability where supported, hyperlinks, bookmarks and labels.
3. Compare decoded original page content streams and resource graphs, all page boxes, rotation, page order, and existing annotations. Permit only explicitly intended annotation/resource additions. Byte-identical whole files are not expected; unchanged original content is required.
4. Render with an independent PDF engine before/after. With added annotations removed from a test copy, compare the base page exactly. With annotations present, compare outside their full appearance bounds; inspect transparency and text visually.
5. Exercise repeated edits, undo/redo, save failures, close/quit during save, external changes, low disk space, and documents with existing CAD annotations/forms/links.
6. Measure save time and size growth across representative architectural files. Set targets from the baseline and actual disk environment; investigate disproportionate whole-document work or growth. Never mask unfinished saves with success UI.
7. Run existing OCR, hyperlinks, viewer navigation, flatten/unflatten and lossless-reduce regressions. Stable v4.2 stays available until the local milestone is accepted.

## Delivery sequence

Foundation + working rectangle local build → user trial → everyday review tools in small batches → advanced tools → reusable tool sets → measurement → parity review.

Do not assign dates or release numbers before the foundation establishes realistic effort. The first deliverable is a working, verified rectangle workflow, not a toolbar populated with inactive controls.

### Polygon local milestone

Polygon (Shift+P) is available in the local trial alongside Polyline (Shift+N). Closed polygons have independent fill colors or No Fill; polylines remain unfilled. Saved polygons use portable vector annotations and preserve the original page graph. Whole-shape movement and individual vertex dragging are supported. Selection follows the path with handles at each node; opacity remains future work. Cross-app acceptance and save-latency investigation remain release gates.
