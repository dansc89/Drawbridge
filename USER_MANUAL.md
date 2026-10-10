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

Select Drawbridge markups to move them, change their color or line weight, or delete them. Polygon and polyline handles follow their vertices. Polygons support fill; polylines remain open lines. Use `Cmd+Z` to undo and `Shift+Cmd+Z` to redo. Standard unlocked imported annotations can also be selected, moved, and deleted with Undo/Redo. Their original appearance and metadata are preserved when saving. Imported text, style, and node editing are not yet supported; those controls are disabled when an imported markup is selected. Flattened page content and locked annotations cannot be selected as editable markups. Page-combining and page-conversion tools are not yet available.

## Drawing measurements

1. Choose **Measurements > Set Drawing Scale…** or click **Scale…** in the markup toolbar. Pick an architectural preset such as `1/8" = 1'-0"`, a metric ratio, or a custom inches-to-feet scale.
2. Enter the PDF page numbers to apply it to, such as `1, 3-6, 9`. Multiple selections in the Pages sidebar populate the page list. Verify the scale against a known drawing dimension before measuring.
3. Choose **Area** (`Shift+A`) and click each boundary corner. Click the first corner again, double-click the final corner, or press Enter to close the area.
4. Choose **Perimeter / Length** (`Shift+L`) and click along a path. Click the first corner again to measure a closed perimeter. Double-click the last point or press Enter to measure an open path's total distance.

Choose **Measurements > Calibrate Drawing Scale…** to calibrate a resized drawing against a known dimension. Click both endpoints, enter the distance in feet or meters, and select the PDF pages that share this scale. Feet accept decimals or feet and inches (for example, `20' 6 1/2"`). Calibration is saved with the pages and recalculates existing measurements; Undo restores the previous scale and totals. The PDF page size does not change.

Hold **Shift** while placing points to constrain each segment to horizontal or vertical directions. This also works with lines, arrows, polylines, polygons, calibration, and the pen. Shift-drag creates squares with Rectangle and circles with Ellipse. Shift-dragging a selected markup constrains its movement to one axis. **Backspace/Delete** removes the most recent unfinished point, allowing you to correct a boundary without restarting. Escape cancels an unfinished measurement. Crossed area boundaries are rejected. Measurements show square feet/meters for area and feet/meters for distance. They appear in the Markups List with the author's name. Move or edit their nodes to recalculate the value. Changing a page's scale recalculates measurements on that page; Undo/Redo restores both scales and totals.

Scale settings and measurement labels persist inside the PDF. Saved labels are visible in other PDF viewers. Drawbridge-specific measurement editing is not guaranteed in other applications. These remain vector annotations; saving does not rasterize or rebuild the original drawing content.

Each page has one scale. Reduced sheets and details at a different scale need verification. Automatic snapping to drawing geometry, multiple scale regions on one page, curved measurements, and takeoff exports are not implemented. Pages with non-default PDF `/UserUnit` are rejected rather than producing misleading values. A measurement can have up to 512 corners.

## Snapshot

Choose **Edit > Snapshot** (`G`) or the camera-viewfinder toolbar button, then drag a box around the area to copy. **Polygon Snapshot** (`Shift+G`) follows clicked corners; double-click, press Return, or click the first corner to finish. Escape cancels an unfinished capture.

Move the pointer over the destination page and press **Cmd+V**. The snapshot is pasted at its original paper size, independent of zoom. Rotated destination sheets retain the captured orientation. Drag a pasted snapshot to move it, use **Cmd+C** to copy it again, or Delete to remove it. Undo and redo apply to pasting, moving, and deleting. Snapshots cannot be stretched by dragging selection corners, so their scale remains unchanged.

Snapshots include the selected drawing content and visible markups. The area outside a polygon is transparent. Vector linework stays vector; source images retain their original resolution. Capture does not add a markup until you paste. Snapshots appear in the Markups List with their author and are embedded in the PDF, with no separate file required. Save before opening the result in another PDF editor.

The original *paper size* is preserved. If sheets use different drawing scales, the same paper size can represent a different real-world distance on the destination sheet. Snapshot is a copying tool, not a redaction tool. PDFs using nonstandard physical page units are not supported for Snapshot.

## Markup Properties

The right sidebar shows properties for the selected Drawbridge markup, or defaults for the next markup when nothing is selected. Drag its divider to resize it. Use Hide or the toolbar properties button to collapse or reopen it. Choosing another markup tool or selecting a different markup reopens a hidden panel. Choose a custom stroke color, enter a line weight from 0.25 to 72 points, and choose solid, dashed, dotted, dash dot, dash dot dot, or long dash linework. Stroke opacity is independent of polygon fill color and fill opacity. Polygon and area fills can be switched off completely. Text boxes support sizes from 6 to 144 points. These settings are retained through save and reopen. Snapshot preserves the captured appearance, and imported markups currently support moving and deletion rather than style editing.

When a markup is selected, these changes edit it and support Undo. When nothing is selected, they set defaults for your next markup. Editing a selection does not silently change drawing defaults. The sidebar displays custom values accurately instead of showing the nearest preset.

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
