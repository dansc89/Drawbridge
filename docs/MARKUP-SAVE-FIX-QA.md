# Markup save repair — October 5, 2026

Existing owned markups can have duplicate identifiers when copied by a PDF editor.
The writer rejected the entire save when those identifiers were duplicated.
Capture now assigns a distinct, stable identifier to each duplicate without changing
its geometry or appearance. Imported consultant markups remain outside this repair.

Save verification now compares the reachable PDF object graphs directly, including
encoded stream data, while allowing qpdf to renumber references. Traversal uses a
work list to handle deep cyclic graphs. Equivalent Foundation JSON number spellings
are canonicalized without a rounding tolerance. Page drawing streams and raster
images are neither rendered nor recompressed during markup saving.

The full stream-decoding check has been removed from the interactive save path.
The candidate is still reparsed and verified for original content, markup records,
source-file changes, and size growth before the atomic commit. A full qpdf check
was also run separately on the architectural output and passed.

Validation:

- Final suite: 114 tests, 15 optional corpus tests skipped, no failures.
- Architectural application save: approximately 1.4 seconds, preserving four
  existing rectangles and adding a fifth. Before optimization, the standalone
  save took approximately 18 seconds; the application rejected duplicate IDs.
- Architectural corpus output: approximately 1.4 seconds; civil output: 0.53 seconds.
- Independent PyMuPDF verification across 111 pages: identical decoded drawing
  bytes, encoded raster image bytes, media/crop boxes, rotations, and rendered
  pixels with annotations disabled. Annotation counts increased by exactly one.
- Architectural output opened in Apple Preview; the existing and added rectangles
  were visible over the original cover page.
- Regression coverage includes copied identifiers, repeated capture stability,
  a 10,000-object cyclic graph, changed stream bytes and rotation, and JSON numeric
  round trips that must not conceal changes or confuse booleans with numbers.

All architectural testing used private local copies. Source documents were not
modified or committed to the repository. The local test bundle is separate from
the published application; these changes have not been released to GitHub.
