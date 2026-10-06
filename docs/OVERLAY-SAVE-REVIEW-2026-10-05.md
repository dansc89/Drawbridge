# Overlay save failure

The reported nine-page overlay reproduced a strict original-content verification failure. It was neither encrypted nor signed. Candidate inspection showed original pattern matrices with values of -0.0000000000000099 became zero after a JSON update. An ordinary qpdf stream-preserving rewrite did not change them; the JSON update was the trigger.

Foundation emitted those numbers as -9.9e-15. The JSON-to-PDF real-number conversion did not retain the exponent form. The fix expands numeric tokens lexically to exact decimal notation, without floating-point calculations, tolerances, or alterations to quoted strings. It applies to all qpdf JSON patch write paths. Original stream and object verification remains intact.

Validation: 127 tests executed with native integration and the overlay/civil corpus, 13 optional skips, zero failures. Application saves on the overlay completed in 0.57, 0.40 and 0.40 seconds. Independent MuPDF comparisons confirmed exact encoded content streams, original rendered pixels and page geometry on all nine pages. Synthetic end-to-end fixtures include tiny catalog values and all seven tools through repeated save, Flatten, Reduce and Unflatten at four rotations. Private document copies and diagnostics were kept outside Git.

The original user file and its in-memory unsaved markups were not modified during investigation.
