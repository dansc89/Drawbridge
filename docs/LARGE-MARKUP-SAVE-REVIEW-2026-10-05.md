# Large drawing-set markup save review

Private XX.pdf reproduction: 124 pages, approximately 155 MB, 17,998 objects and 6,376 streams. User originals remained untouched; experiments used private copies.

The existing writer repeatedly parsed large inline base64 raster strings, serialized unchanged objects, and could not retain its verification cache for this document because the source alone exceeded the 96 MB cache limit. Baseline application saves took 8.05, 7.48 and 7.21 seconds.

Changes:
- Replace encoded stream payloads with SHA-256 fingerprints before JSON parsing. Continue comparing stream dictionaries and the reachable original object graph before committing.
- Write a partial qpdf patch containing changed/new objects rather than serializing all original objects.
- Retain a compact verified graph with a whole-file fingerprint instead of retaining original PDF bytes. The graph remains bounded to 96 MB; external changes invalidate it.
- Keep original PDF stream bytes in qpdf's input; supply inline appearance data only for newly generated annotation streams.

Validation:
- Full regression suite: 130 tests, 15 skipped, zero failures.
- New verification regression rejects altered encoded stream bytes and malformed payloads.
- Production application benchmark adding six rectangles per pass: 5.04 seconds first save, 3.13 and 3.09 seconds subsequent saves. All saves succeeded and reopened with expected annotations; the strict three-second performance assertion still fails.
- Independently compared all 124 original page content streams, page boxes and rotations after 18 additions: identical. Original page pixels also matched on pages 1, 61 and 124 with annotations excluded.

This is an improvement, not completion of the latency target. A first save still inspects both complete PDFs, and subsequent saves still inspect the complete candidate. Further work should remove this whole-file cost using a properly validated incremental annotation writer, rather than weakening preservation checks. No GitHub release was issued.
