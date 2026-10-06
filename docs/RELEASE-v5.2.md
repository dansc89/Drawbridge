# Drawbridge v5.2

Drawbridge follows the macOS light/dark appearance setting and refreshes custom interface backgrounds when the setting changes. PDF page and markup colors stay unchanged.

The markup toolbar now includes Pen (P): drag to draw freehand using the selected stroke color and width. Strokes use the existing annotation-only persistence, selection, delete, undo and redo workflows; Escape cancels a draft.

Annotation mutations refresh PDFKit's nested page-rendering views so deleted markups do not leave stale images. The verified annotation writer retains a separate production call boundary after a packaged-app pen-save regression was reproduced during QA.

The release workflow runs the regression suite in production mode before building and notarizing assets.

Validation: production regression suite completed with 145 tests, 15 environment-dependent skips, and zero failures. Hands-on packaged-app checks covered Pen drawing/style, save, delete, undo/redo, and quit/reopen. See [validation report](USABILITY-v5.2.md).
