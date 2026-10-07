# Drawbridge v5.4

Fixes markup saves after an opened PDF or its containing folder is moved. Drawbridge follows verified file moves and offers a recovered copy when the original is missing or has changed externally. Recovered copies preserve the version originally opened and its markups without overwriting another version of the PDF.

Unchanged PDFs replaced by another application or file provider are accepted only after exact content verification. PDFKit reads from a retained opening snapshot, while background saves use frozen markup and navigation records. Repeated Save requests are coalesced; an already-clean document skips saving. A cache bookkeeping failure no longer reports a successfully committed PDF as a failed save.

Annotation saves append changed PDF objects while retaining the original content. Validation covers source replacement, folder moves, recovery, concurrent navigation edits, and repeated saves. Five real drawing sets of 25–155 MiB and 30–205 pages passed 15 saves, including 100 additional markups. In the local application tests, the largest set saved in 1.54 seconds initially and 0.84–0.97 seconds afterward. Timings depend on hardware and storage.

Encrypted and digitally signed PDFs remain unsupported for markup saving. These PDFs are rejected safely; the app does not rewrite their original page content.
