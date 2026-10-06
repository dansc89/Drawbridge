Drawbridge v4.9 fixes a reproduced markup-save failure on overlay PDFs containing very small numbers in pattern transformation matrices.

The JSON patch writers now expand exponent-form numeric tokens into exact decimal notation before passing them to the PDF writer. This prevents small original values from becoming zero. Original-content verification remains strict; the fix also applies to navigation, Flatten, Unflatten and Reduce patch writes.

Validation: 127 regression tests executed, 13 optional tests skipped, zero failures. The reported nine-page overlay saved through the application in 0.57 seconds initially and 0.40 seconds on subsequent saves. Independent rendering and encoded-stream comparisons confirmed unchanged original content and page geometry on all nine pages. Regression cases cover exact exponent expansion, quoted text, large numbers, and save/Flatten/Reduce/Unflatten at all four rotations with tiny original values.
