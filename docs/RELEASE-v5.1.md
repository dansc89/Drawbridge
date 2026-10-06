# Drawbridge v5.1 — faster markup saves and interaction

Build 149.

- Fix repeated markup saves in synced folders: use the annotation writer’s verified local candidate directly, removing a redundant outer staging/replacement and retaining prepared inspection for the final PDF.
- Fix queued Save requests so edits made after an earlier snapshot are saved. Coalesce repeated requests when there are no newer edits.
- Collect owned annotations once per page when saving, instead of scanning the drawing set twice.
- Recount PDF Contents only on edited pages.
- Update drawing-preview geometry without refreshing the entire toolbar on every pointer movement.
- Add optional end-to-end save diagnostics and compare rendered pixels directly in visual regression checks.

## Validation

- Full local suite: 140 tests, 15 optional/environment-dependent skips, zero failures.
- Production application save completion on a disposable copy of XX.pdf, 124 pages / 161,968,124 bytes, six new annotations per pass:
  - Local storage, no inspection prepared beforehand: 1.305 / 0.591 / 0.522 seconds.
  - Actual Google Drive My Drive folder: 1.107 / 0.489 / 0.462 seconds. Background preparation was invalidated by changing provider metadata, so the first save prepared on demand; subsequent saves reused the verified inspection.
- Reopen and exact annotation-record checks on every save; file growth remains bounded. Across 18 additions, 20,505 bytes were appended and every original byte remains an exact prefix. qpdf full check reports no syntax or stream encoding errors.
- Visual checks compare image dimensions and exact normalized sRGB pixels, rather than TIFF metadata. Coverage includes original content after save/flatten/reduce/unflatten, rotations, shapes, and visible text.
- Synced-folder measurements cover successful local file commits, not completion of remote server upload. They do not promise a fixed latency for every file, machine, storage provider, or externally changing document.

The release workflow creates a draft after tests, signing, and app/DMG notarization. Publish only after downloaded artifact signature, notarization, and version checks pass.
