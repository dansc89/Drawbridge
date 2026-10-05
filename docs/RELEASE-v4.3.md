Drawbridge v4.3 adds a separate markup toolbar for reviewing drawing sets while retaining the existing indexing, hyperlinking, flattening, and file-size reduction tools.

- Add rectangles, ellipses, lines, arrows, text boxes, polylines, and filled polygons.
- Type and edit text directly on the PDF page.
- Select polygon and polyline nodes individually and drag them without an oversized rectangular selection box. Empty space around a path no longer selects it.
- Use E for ellipse, R for rectangle, L for line, Shift+N for polyline, and Shift+P for polygon.
- Adjust stroke color, line weight, text size, and polygon fill; move, delete, undo, and redo Drawbridge-authored markups.
- Use distinct History and Pages arrows in the centered bottom status bar.

Markup saves use vector PDF annotations and verify that original page content, resources, page geometry, and existing consultant annotations remain intact before replacing the file. Imported annotations remain protected from these new editing tools. Encrypted and signed PDFs are not supported for markup saves yet. Save time can vary with document size and complexity.

Validation covers save/reopen and undo/redo at all four rotations, nonzero crop/media origins, original-content comparisons, and the existing PDF processing regressions. The distributed app and DMG are Developer ID signed, notarized, and stapled by the release workflow.
