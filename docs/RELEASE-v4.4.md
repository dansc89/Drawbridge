Drawbridge v4.4 completes the markup keyboard shortcuts and fixes the v4.3 crash caused by PDFKit's background form detection accessing the document.

- V: Select markups
- R: Rectangle
- E: Ellipse
- L: Line
- A: Arrow
- T: Text box
- Shift+N: Polyline
- Shift+P: Polygon

Shortcuts work across the PDF canvas, sidebar, and toolbar, while text entry retains normal typing. Tooltips show the assigned keys. Delete removes the selected markup; Command+Z and Shift+Command+Z undo and redo.

The crash fix retains PDFKit's native document getter and binds the markup session explicitly when opening or closing documents. A regression test exercises 100 background document reads through the Objective-C entry point used by PDFKit.

Original PDF content preservation and annotation saving remain unchanged. Release validation includes markup saves at every rotation, shortcut modifiers, background document access, navigation, hyperlinks, OCR matching, flattening, file reduction, and toolbar behavior. The release workflow signs, notarizes, and staples the app and DMG.
