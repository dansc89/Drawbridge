# Drawbridge User Manual

Drawbridge is a macOS PDF viewer for architectural drawing sets, with sheet bookmarks, hyperlinks, and editable vector markups.

## Open and Navigate

1. Open an existing PDF with **File > Open PDF...** (`Cmd+O`).
2. Use the left sidebar to switch between page thumbnails and bookmarks.
3. Scroll over the PDF to zoom around the pointer. Use **View > Zoom In**, **Zoom Out**, **Actual Size**, or **Fit Width** for additional zoom controls.
4. Use the arrow keys to move between pages, or hold Control while scrolling. Use `Option+Left` and `Option+Right` to move backward and forward through navigation history.
5. Use **Edit > Find…** (`Cmd+F`) to search the document. Select and copy PDF text with `Cmd+C`.

## Manage Pages and Bookmarks

In **Pages**, click a thumbnail to open a sheet. The highlighted thumbnail follows the current page, and thumbnails refresh after markup changes. PDF Contents details can be expanded when needed.

Use **Shift-click** for a range or **Command-click** for separate selections in either sidebar. With the sidebar focused, **Cmd+A** selects all entries. Press **Backspace/Delete**, or right-click and choose **Delete Selected Page(s)…** or **Delete Selected Bookmark(s)…**. Confirm the deletion, or cancel to retain the selection.

Deleting pages removes those sheets and their annotations; at least one page must remain. Deleting bookmarks removes navigation entries, not pages. Removing a bookmark group also removes its children. **Cmd+Z** undoes deletion and **Shift+Cmd+Z** redoes it, including after saving while the same document remains open. Save to persist the change. Closing the document clears Undo history.

Right-click a single page to rename its label, or a single bookmark to rename it and optionally update the matching page label.

## Generate and Manage Bookmarks

Choose **Bookmarks > Auto-Generate Sheet Names/Bookmarks…** (`Cmd+Shift+A`), or use the sheet-naming toolbar button. Follow the prompts to identify sheet numbers and titles, then apply the results.

In the **Bookmarks** sidebar, right-click a bookmark to rename or delete it. When renaming, you can also update the matching page label. Deleting a bookmark removes the navigation entry, not its PDF page. Deleting a bookmark group also removes its child bookmarks. Bookmark deletion supports Undo.

## Hyperlinks

Choose **Hyperlinks > Batch Link Sheet Numbers…** (`Cmd+Shift+H`), or use the link toolbar button. Follow the prompts to create links from sheet references to their destination pages.

Click a hyperlink to follow it. Use **View > Show Hyperlink Highlights** to show or hide link highlights, and **View > Back** to return after following a link.

## Save

- **File > Save** (`Cmd+S`) saves bookmark, hyperlink, and markup changes.
- **File > Save As PDF...** (`Cmd+Shift+S`) saves a separate PDF copy.
- **File > Close** (`Cmd+W`) closes the current document.

Markup saving appends annotation changes without rasterizing the drawing pages. Encrypted or digitally signed PDFs are not supported for this save path. If a save fails, edits remain open; inspect the reported error before closing the document.

## Markups

The separate markup toolbar supports pen (`P`), rectangle (`R`), ellipse (`E`), line (`L`), arrow (`A`), polygon (`Shift+P`), polyline (`Shift+N`), and text (`T`). The active tool is highlighted. `V` returns to selection; Escape cancels an unfinished drawing. Click a line or arrow's start and then its end. Draw a text box and type on the page; double-click an existing Drawbridge text annotation to edit it.

Select Drawbridge markups to move them, change their color or line weight, or delete them. Polygon and polyline handles follow their vertices. Polygons support fill; polylines remain open lines. Use `Cmd+Z` to undo and `Shift+Cmd+Z` to redo. Standard unlocked imported annotations can also be selected, moved, and deleted with Undo/Redo. Their original appearance and metadata are preserved when saving. Imported text, style, and node editing are not yet supported; those controls are disabled when an imported markup is selected. Flattened page content and locked annotations cannot be selected as editable markups. Measurement, snapshot pasting, page-combining, and page-conversion tools are not yet available.

## Markup Properties

Click the sliders button in the markup toolbar to open a compact, nonmodal inspector. Choose a custom color, enter a line weight from 0.25 to 12 points, or enter a text size from 6 to 144 points. Polygon fill can be switched off or given a custom color. Fractional text sizes are retained through save and reopen. The current writer supports opaque colors; opacity and font-family controls are not part of this pass.

When a markup is selected, these changes edit it and support Undo. When nothing is selected, they set defaults for your next markup. Editing a selection does not silently change drawing defaults. The toolbar displays custom values accurately instead of showing the nearest preset.

## Switching Tabs

Click a document tab, or cycle using the existing next/previous document commands. Tab order remains stable. Returning to a document restores its page, zoom, navigation history, and search query. Saved inactive PDFs are cached with a limit of two documents and 256 MiB of source-file sizes; larger or evicted files reload while retaining their viewing position. External changes invalidate cached copies.

Unsaved changes still require Save, Discard Changes, or Cancel before switching. Discarded edits are never reused from the cache. Markup Undo history is cleared when switching documents; retaining independent Undo stacks and unsaved sessions per tab remains future work.

## Print

Choose **File > Print…** (`Cmd+P`) for the document, or **File > Print Current Sheet…** to start with the displayed sheet's page range. The native macOS dialog lets you change the range, paper size, orientation, and scale and save print output as a PDF.

Printing starts at **100% actual size**, without automatic rotation or resizing. Check the dialog preview and choose sufficiently large paper or adjust scaling for smaller paper. Print output includes annotations marked for printing, including unsaved Drawbridge markups. It does not save or change the open PDF. **View > Invert** changes only the on-screen colors; printing uses the original colors.

## Flatten Existing Markups

Click the **Flatten PDF** toolbar button beside the hyperlink button, or choose **File > Flatten PDF…**, to flatten and save the PDF you have open. Flattening makes supported visible consultant markups part of the page content, so those markups cannot be edited individually while flattened. Pending bookmark/link changes are saved first. Drawbridge verifies the flattened result before replacing the file, then reloads it. Completion means the write has finished. The button then changes to **Unflatten PDF**: click it again to restore the original editable annotations and save the same file. Recovery is embedded in PDFs flattened by this version and survives closing/reopening. Bookmark, page-label, and hyperlink changes made in Drawbridge are preserved when unflattening. Older files flattened without recovery data cannot be unflattened. If page content or geometry was changed after flattening, Unflatten stops rather than overwrite those changes.

Drawbridge preserves vector drawing content, page size/crop/rotation, bookmarks, page labels, clickable links, and form fields. Markups with missing or unsupported appearance streams and hidden items remain unchanged; the completion message reports them. Redundant AutoCAD SHX text comments with no appearance and an explicit zero-width border are removed; the actual drawing text remains in the page content. Other unsupported annotations are retained. Flattening does not guarantee a smaller file.

Encrypted PDFs and PDFs with signature fields are not supported. Redaction annotations are retained: this command is not a secure redaction tool.

## Reduce File Size

Choose **File > Reduce File Size…** or the clamp toolbar button. Compression is lossless: image resolution, vectors, text, and supported interactive content are preserved. Drawbridge verifies the result and replaces the open file only when the result is smaller. Already-compressed images may provide little or no reduction. There is no lossy image-quality or downsampling control.

## Settings

Use **Drawbridge > Keyboard Shortcuts…** to review shortcuts and **Drawbridge > Performance Settings…** for performance preferences.

## Review Markups

Choose **View > Markups List**, or click **Markups** in the bottom bar. The list shows markup type, page, comment, and author across the document. Click a row to navigate to that annotation. Search by text or author. Shift-click or Command-click to select multiple rows, then press Backspace/Delete or choose **Delete Selected**. Cmd+Z restores deleted markups. Links, form controls, and AutoCAD SHX text helpers are excluded from this review list. Locked annotations remain listed but cannot be deleted. Clear the search before checking whether any review markups remain.

Choose **Drawbridge > Markup Author…** to set the name recorded on new markups. The default is your Mac account’s full name. Existing annotations from other apps retain their authors.
