<p align="center">
  <img src="Assets/readme/drawbridge-hero-v017.png" alt="Drawbridge" width="100%" />
</p>

Drawbridge is a native macOS PDF viewer for architectural drawing sets, focused on generating sheet bookmarks and hyperlinks. Open, search, and navigate PDFs, generate sheet bookmarks and hyperlinks, and add editable vector markups without changing the original drawing content. Flatten/Unflatten and lossless file reduction are also available. Measurement and page-conversion tools are not yet available.

## Requirements

- Apple Silicon Mac (M1 or newer)
- macOS 13.0 or newer

## Download

Get the latest release here:

https://github.com/dansc89/Drawbridge/releases/latest

Download the `.dmg`, open it, then drag **Drawbridge.app** into **Applications**.

## Quick Start

1. Open Drawbridge.
2. Open an existing PDF.
3. Use **Bookmarks > Auto-Generate Sheet Names/Bookmarks…** to name sheets and create bookmarks.
4. Use **Hyperlinks > Batch Link Sheet Numbers…** to link sheet references.
5. Save the PDF, or choose **File > Save As PDF...** to save a copy.
6. Use **File > Flatten PDF…** to make existing consultant markups permanent in the PDF you have open, while preserving drawing quality and interactive links. Click the same button again to Unflatten.
7. Use **File > Reduce File Size…** (or the clamp toolbar button) for lossless compression. Drawbridge verifies decoded PDF content and saves over the open file only when the result is smaller. Image resolution, vector graphics, text, navigation, forms, and Unflatten recovery are preserved; JPEG images may already be compact.

Processing dialogs show the current stage and page counts. Cancel stops at the next safe page or processing-step boundary; Escape also cancels OCR. Canceling bookmark review leaves existing bookmarks intact. Duplicate OCR sheet numbers are reported and excluded from hyperlink destinations instead of guessing a target.

## Viewing drawing sets

- **Go to Sheet (⌘L):** search sheet labels, bookmark titles, or page numbers. Arrow keys select a result; Return opens the whole sheet. Duplicate labels remain separate pages.
- **Fit Entire Page (⌘9):** center the complete sheet. **Fit Width (⌘⌥9)** fits its displayed width while keeping your reading position.
- **Find (⌘F):** search runs asynchronously with live progress. Change the query to cancel the previous search; ⌘G / ⇧⌘G move between results. Large result sets show a `+` and a prompt to narrow the query.

## Marking up drawings

Use the separate markup toolbar, or press **R** (rectangle), **E** (ellipse), **L** (line), **A** (arrow), **Shift+P** (polygon), **Shift+N** (polyline), or **T** (text). Press **V** to select a markup. Line and arrow tools use two clicks: start, then end. Text boxes let you type directly on the page. Use **Cmd+Z** to undo and **Shift+Cmd+Z** to redo.

Drawbridge can edit its own markups; imported annotations remain visible and preserved. **Invert** changes the display only, leaving saved PDFs and print output unchanged.

Native printing is available in the next build: **File > Print… (Cmd+P)** or **Print Current Sheet…**. The macOS dialog offers paper size, orientation, scale, and page ranges. Output starts at **100% actual size**; select paper large enough for your drawing, or adjust the scale in the print dialog.

## Support

If you hit an issue, open a GitHub issue with:
- what file you opened
- what action you took
- what happened vs expected behavior

## Developer Docs

Developer/build/release docs are in `DEVELOPMENT.md`.
For trusted macOS distribution (Developer ID signing + Apple notarization), see the same doc.
User manual is in `USER_MANUAL.md`.
