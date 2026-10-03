# Drawbridge User Manual

Drawbridge is a macOS PDF viewer for architectural drawing sets, focused on bookmarks and hyperlinks.

## Open and Navigate

1. Open an existing PDF with **File > Open PDF...** (`Cmd+O`).
2. Use the left sidebar to switch between page thumbnails and bookmarks.
3. Scroll over the PDF to zoom around the pointer. Use **View > Zoom In**, **Zoom Out**, **Actual Size**, or **Fit Width** for additional zoom controls.
4. Use the arrow keys to move between pages, or hold Control while scrolling. Use `Option+Left` and `Option+Right` to move backward and forward through navigation history.
5. Use **Edit > Find…** (`Cmd+F`) to search the document. Select and copy PDF text with `Cmd+C`.

## Generate and Manage Bookmarks

Choose **Bookmarks > Auto-Generate Sheet Names/Bookmarks…** (`Cmd+Shift+A`), or use the sheet-naming toolbar button. Follow the prompts to identify sheet numbers and titles, then apply the results.

In the **Bookmarks** sidebar, right-click a bookmark to rename or delete it. When renaming, you can also update the matching page label. Deleting a bookmark removes the navigation entry, not its PDF page. Deleting a bookmark group also removes its child bookmarks. Bookmark deletion supports Undo.

## Hyperlinks

Choose **Hyperlinks > Batch Link Sheet Numbers…** (`Cmd+Shift+H`), or use the link toolbar button. Follow the prompts to create links from sheet references to their destination pages.

Click a hyperlink to follow it. Use **View > Show Hyperlink Highlights** to show or hide link highlights, and **View > Back** to return after following a link.

## Save

- **File > Save** (`Cmd+S`) saves bookmark and hyperlink changes.
- **File > Save As PDF...** (`Cmd+Shift+S`) saves a separate PDF copy.
- **File > Close** (`Cmd+W`) closes the current document.

Markup, drawing, measurement, snapshot pasting, page-combining, and page-conversion tools are not available. Existing PDF content remains visible; removing the tools does not remove annotations already stored in a PDF.

## Flatten Existing Markups

Click the **Flatten PDF** toolbar button beside the hyperlink button, or choose **File > Flatten PDF…**, to flatten and save the PDF you have open. Flattening makes supported visible consultant markups part of the page content, so those markups cannot be edited individually while flattened. Pending bookmark/link changes are saved first. Drawbridge verifies the flattened result before replacing the file, then reloads it. Completion means the write has finished. The button then changes to **Unflatten PDF**: click it again to restore the original editable annotations and save the same file. Recovery is embedded in PDFs flattened by this version and survives closing/reopening. Bookmark, page-label, and hyperlink changes made in Drawbridge are preserved when unflattening. Older files flattened without recovery data cannot be unflattened. If page content or geometry was changed after flattening, Unflatten stops rather than overwrite those changes.

Drawbridge preserves vector drawing content, page size/crop/rotation, bookmarks, page labels, clickable links, and form fields. Markups with missing or unsupported appearance streams and hidden items remain unchanged; the completion message reports them. Redundant AutoCAD SHX text comments with no appearance and an explicit zero-width border are removed; the actual drawing text remains in the page content. Other unsupported annotations are retained. Flattening does not guarantee a smaller file.

Encrypted PDFs and PDFs with signature fields are not supported. Redaction annotations are retained: this command is not a secure redaction tool.

## Settings

Use **Drawbridge > Keyboard Shortcuts…** to review shortcuts and **Drawbridge > Performance Settings…** for performance preferences.
