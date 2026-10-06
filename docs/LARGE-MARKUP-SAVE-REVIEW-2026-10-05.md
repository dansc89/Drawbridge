# Large drawing-set markup save review

Reproduction used private copies of XX.pdf: 124 pages, approximately 155 MB, 17,998 objects and 6,376 streams. The user's original was never modified.

## Root cause

Small markup changes still went through a whole-document qpdf rewrite. Inspection also transported raster streams as large inline base64 strings and parsed/compared them through Foundation. The original verification cache discarded this document because its bytes exceeded the 96 MB cache limit. Baseline application saves took 8.05, 7.48 and 7.21 seconds. The first optimization reduced production times to 5.04, 3.13 and 3.09 seconds, but still failed the three-second target.

## Final change

Annotation saves now append a PDF revision to a staged copy of the original bytes. Only changed dictionaries and new vector appearance streams are serialized. Original content, image and font streams cannot be replaced by this writer. Cross-reference streams remain streams when the source uses them; writing a classic cross-reference revision after this source's stream passed qpdf but was rejected by Apple's reader, so compatibility is explicitly checked before committing.

Inspection excludes raster payloads. The bounded verification cache retains a compact object graph and a whole-file fingerprint, rather than retaining the large original PDF. Source changes invalidate the cache and changes during saving prevent replacement. Every candidate must retain the exact original byte prefix, preserve the reachable original content graph, contain the expected markups, and reopen with the expected page count in Apple's PDF reader. Commits retain the existing atomic replacement path.

Saving unchanged markup/navigation is a no-op and does not accumulate revisions. Actual edits append small vector objects; old revisions remain in the PDF. This favors safe fast annotation saves over whole-document compaction.

The application delegate is also explicitly kept alive throughout the event loop because NSApplication's delegate reference is weak. This prevents optimized code from shortening the window owner's lifetime; it is not the measured cause of save latency.

## Validation

- Full regression suite: 131 tests, 15 optional tests skipped, zero failures. Coverage includes all seven markup kinds, page rotations, text, links, imported annotations, deletion, flatten/reduce/unflatten, external changes, and repeated saving.
- Added compressed-object/xref-stream regression: Unicode text saves and reopens through PDFKit, original bytes remain an exact prefix, and an unchanged second save leaves the entire file identical.
- Production application benchmark on the 155 MB PDF, adding six rectangles per pass: **2.23 seconds initial, 1.74 and 1.68 seconds subsequent**. All three saves passed the strict three-second assertion and reopened with the expected records.
- Independent MuPDF comparison: all 124 original raw page content streams, page boxes and rotations remained identical. Original-content pixels matched on pages 1, 61 and 124 with annotations excluded. Eighteen additional annotations across three saves added approximately 149 KB.
- Visually opened the resulting large PDF in Apple Preview: original cover content and saved red markups rendered correctly.
- Packaged-app interaction testing was limited by computer-use accessibility timeouts after opening PDFs. The production application persistence benchmark drives the real view controller/PDF view, but does not replace a full packaged UI interaction review.

No public GitHub release or replacement of the installed application was made during this review.
