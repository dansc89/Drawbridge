# Drawbridge v5.3

Fixes markup saves that could be rejected after macOS granted access to an opened PDF. Permission metadata changes are accepted only when the file still matches a frozen opening snapshot byte for byte. External PDF edits continue to block overwriting, including same-size edits with restored modification dates. Annotation saves retain the original PDF bytes and append only the changed objects.

Adds a compact Markup Properties inspector for custom colors, precise line weights, fractional text sizes, and polygon fill. Values apply on Return or when leaving the field, support Undo/Redo, and retain exact sizes after saving and reopening. Editing selected markups does not change new-markup defaults.

Document tabs retain page, zoom, view history, search query, and tab order. A bounded cache speeds returning to saved documents; externally changed files reload. Native printing includes current-sheet and document commands with actual-size output and original colors, even with Invert enabled.

Validated rectangle, ellipse, line, arrow, polygon, polyline, pen, and inline text through the signed app and reopened the saved PDF in Apple Preview. Checked original-byte preservation, rotation/crop geometry, imported annotations and links, repeated saves, and flatten/reduce/unflatten compatibility. Production save benchmarks on a 124-page, 155 MiB drawing set completed in approximately one second or less after opening inspection.

Encrypted and signed PDFs remain unsupported for markup saving. Validation stops safely rather than rewriting original page content.
