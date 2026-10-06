# Two-click line and arrow placement

Line (L) and Arrow (A) now use a first click for the start and a second click for the endpoint. Mouse movement previews the pending annotation. Mouse release does not complete it. Successful placement returns to Select; Escape cancels the draft. Zero-length and cross-page second clicks do not create a markup.

Validation:
- Regression suite: 129 tests, 15 skipped, zero failures.
- New interaction test exercises keyboard activation, first-click mouse release, hover/drag, second-click completion, and Escape on pages rotated 0, 90, 180, and 270 degrees.
- Isolated native app: activated both tools using L/A, placed each with two clicks, confirmed selection state and annotation counts, cancelled another draft, and saved a disposable PDF.
- Independent inspection confirmed two new Line annotations and identical original page content streams after saving.

The installed application and original user PDFs were not modified. This change is available in the local test build; it has not been released to GitHub.
