# Drawbridge

A native macOS PDF viewer and markup editor for architectural drawing sets. Navigate sheets, generate bookmarks and hyperlinks, and add editable vector markups while preserving the original drawing content.

<p align="center">
  <img src="Assets/readme/drawbridge-hero-v57-pages.png" alt="Drawbridge showing architectural drawings with page thumbnails and a separate markup toolbar" width="100%" />
</p>

Demo drawing: *Marilyn’s Farmhouse* by Jay Osborne / [FreeFarmhouse](https://www.freefarmhouse.com/), licensed under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/).

## Download

**[Download the latest release](https://github.com/dansc89/Drawbridge/releases/latest)**, signed with Developer ID and notarized by Apple.

Download the **DMG**, open it, and drag **Drawbridge.app** into **Applications**. A ZIP containing the app is also available.

Requires **macOS 13 or newer** on an **Apple Silicon Mac (M1 or newer)**. Intel builds are not currently provided.

Version 1.0 starts the public release series. Earlier version numbers were development releases; their tags remain available for reference.

## What it does

- **Navigate drawing sets:** page thumbnails track the current sheet and refresh after markup changes. Switch to bookmarks, search sheet names, or use separate page and viewing-history controls.
- **Index and link sheets:** generate sheet numbers/titles and bookmarks from title blocks, then batch-link sheet references. Processing dialogs report stages and page progress, with cancellation and review before applying bookmarks.
- **Add vector markups:** pen, rectangle, ellipse, line, arrow, polygon, polyline, and on-page text boxes. The active tool is highlighted; a resizable right properties sidebar offers custom colors, six line patterns, lineweights, text sizes, and separate stroke and polygon fill opacity.
- **Snapshot drawing regions:** capture a box or polygon and paste it onto another sheet at its original paper size. Vector linework stays sharp and snapshots are embedded in the saved PDF.
- **Measure drawings:** apply architectural or metric scales to several pages, calibrate against a known dimension, and trace area, perimeter, or open-path length. Measurement labels and page scales persist in the PDF.
- **Review markups:** open the Markups List to see type, page, comment, and author. Click a row to jump to the annotation, search by text or author, and batch-delete selected markups with Undo. Links and form controls are excluded; locked annotations stay visible.
- **Manage pages and bookmarks:** Shift/Command-select several entries, then press Backspace/Delete or right-click to delete with confirmation. Undo/redo also works after saving while the document remains open. Deleting bookmarks leaves PDF pages intact.
- **Save PDF changes:** save the open file or a separate copy. Markup saves append annotation changes rather than rasterizing or rebuilding drawing pages.
- **Flatten and unflatten:** flatten supported consultant annotations into page content. Drawbridge embeds recovery information so its flattened PDFs can be unflattened after reopening.
- **Reduce file size:** lossless compression with content verification. Image resolution is preserved; already-compressed images may not get smaller.
- **Read and print:** document text search, text selection/copy, fit-page/fit-width views, and native macOS printing. Invert changes on-screen colors only, leaving saved and printed colors unchanged.

PDF Contents details are collapsed by default to leave more space for navigation.

## Quick start

1. Open a PDF with **Cmd+O**.
2. Navigate using **Pages** thumbnails or **Bookmarks**. Use **Go to Sheet (Cmd+L)** to find a sheet, or **Find (Cmd+F)** to search document text.
3. For an unindexed set, choose **Bookmarks > Auto-Generate Sheet Names/Bookmarks…** and review the results. Use **Hyperlinks > Batch Link Sheet Numbers…** to create sheet links.
4. Select a markup tool, draw on the PDF, and use **Cmd+S** to save. **Save As PDF… (Shift+Cmd+S)** creates a separate copy.

Choose **Drawbridge > Markup Author…** to set the name recorded on new markups. It defaults to your Mac account’s full name; imported markups retain their existing authors.

The [user manual](USER_MANUAL.md) covers navigation, page/bookmark deletion, saving, printing, flattening, and tool behavior.

## Markup shortcuts

| Tool | Shortcut |
| --- | --- |
| Snapshot box | G |
| Snapshot polygon | Shift+G |
| Paste snapshot | Cmd+V |
| Select | V |
| Pen | P |
| Rectangle | R |
| Ellipse | E |
| Line | L |
| Arrow | A |
| Polygon | Shift+P |
| Polyline | Shift+N |
| Text box | T |
| Area | Shift+A |
| Perimeter / Length | Shift+L |
| Undo / Redo | Cmd+Z / Shift+Cmd+Z |

The Pen tool displays a pen cursor over the PDF, with the nib aligned to the drawing point.

Hold **Shift** to constrain lines, arrows, pen strokes, and path segments to horizontal or vertical directions. Shift-drag creates squares and circles.

Line and arrow tools use two clicks: start, then end. Text boxes let you type directly on the page. Escape cancels an unfinished drawing. Shortcuts do not activate drawing tools while you are typing text.

## Drawing measurements

Choose **Measurements > Set Drawing Scale…** to apply a preset or custom scale to one or several PDF pages. **Calibrate Drawing Scale…** uses two points and a known distance in feet or meters. Verify the result against a known dimension before taking measurements.

Use **Area (Shift+A)** for a closed boundary. Use **Perimeter / Length (Shift+L)** for a closed perimeter or an open path. Click the first point to close, or press Enter to finish. Backspace removes the last unfinished point; Escape cancels. Editing nodes or changing page scale recalculates the totals and supports Undo/Redo.

Each page has one scale. Automatic snapping to drawing geometry, multiple scale regions, curved measurements, and takeoff exports are not supported. See the [measurement instructions](USER_MANUAL.md#drawing-measurements) for details.

## Current limits

- Sheet-number, title, and hyperlink detection depend on the PDF’s text, scan quality, and layout. References can be missed or matched incorrectly. Review generated bookmarks before applying them and check hyperlink results afterward.
- Processing and save times vary with document complexity, file size, and storage. There is no fixed completion-time guarantee.

- Drawbridge can select, move, and delete standard unlocked markups from other PDF apps, with Undo/Redo. Imported text, style, and node editing are not yet supported. Flattened content and locked annotations cannot be selected as editable markups.
- Secure redaction, page combining/conversion, and general editing of original PDF text are not available.
- File reduction is lossless; there is no lossy image-quality or image-downsampling option.
- Encrypted or digitally signed PDFs are not supported for annotation-only markup saving. Flattening also excludes encrypted PDFs and PDFs with signature fields.
- Unflatten requires recovery information from Drawbridge. Unsupported/hidden annotations are retained, and flattening does not guarantee a smaller file.
- Switching documents requires saving or discarding pending edits and clears markup Undo history. Undo history is not retained after closing a document.

## License

Drawbridge is free and open source. Drawbridge’s original code and documentation are licensed under the [MIT License](LICENSE), permitting use, modification, and redistribution, including commercial use, with the copyright and license notice retained.

Third-party components and demo drawings retain their own licenses. See [third-party notices](THIRD_PARTY_NOTICES.md).

## Privacy and security

PDF viewing, markup editing, and sheet indexing run locally on your Mac. The optional backend prototype is separate from the released app. See [SECURITY.md](SECURITY.md) for private vulnerability reporting and contribution guidelines.

## Support and development

[Report an issue](https://github.com/dansc89/Drawbridge/issues) with your app version, macOS version, the action you took, and what happened. Attach only synthetic or sanitized sample PDFs you have permission to publish. Remove client details, document metadata, annotations, and private file paths from samples and logs. Report security vulnerabilities privately using the [security policy](SECURITY.md).

For the source corresponding to a released build, open the tag listed on its [release page](https://github.com/dansc89/Drawbridge/releases/latest). That tag also contains its `DEVELOPMENT.md` build, signing, notarization, and test instructions.
