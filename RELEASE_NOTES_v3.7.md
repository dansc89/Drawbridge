Drawbridge v3.7 fixes missing automatic sheet links in PDFs with malformed AutoCAD font maps and improves batch-link progress reporting.

- Reads exact sheet references from a disposable copy with repaired Unicode-map metadata when Apple's PDF reader cannot extract the original text. Original drawing streams and font maps remain unchanged when saving links.
- Fixes the missing S202 index link in the 2127 Architectural structural set while keeping S202A, S202B and S202C separate. Link destinations still require unambiguous OCR sheet numbers from the captured title-block region.
- Adds OCR orientation recovery when the initial captured-region reading fails.
- Shows the current page, completed counts, found/missed sheet numbers, elapsed time and stage time estimate; refreshes progress before OCR and lists missed pages directly at completion.
- Retains the existing interface without markup tools.

Validation: focused regressions cover exact reference matching, malformed font-map recovery and ambiguous OCR rejection. The Architectural fixture saved an exact S202 link to page 22 without changing any of its 35 drawing streams, page geometry or original Unicode maps. The local application fix was confirmed by the user.
