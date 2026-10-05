Drawbridge v4.8 improves markup saving and makes selection, text editing and undo more consistent.

- Accelerates repeated saves by reusing a verified inspection only when the PDF still matches byte for byte. Original content is verified on every save.
- Removes repeated annotation searches that grow inefficiently with larger markup sets.
- Makes line and ellipse selection follow their actual geometry and prevents unchanged selections from creating undo actions.
- Fixes keyboard undo/redo while editing text directly on the page, refreshes text style previews and clears false unsaved warnings when cancelling a draft.
- Keeps toolbar drawing defaults consistent after leaving a styled selection.

Validation: 124 regression tests executed, 13 optional tests skipped, zero failures. Manual text editing, keyboard undo/redo and saving were checked, and saved markup types were verified visually in Apple Preview. Independent rendering confirmed unchanged original page content at all four rotations after repeated save, Flatten, Reduce and Unflatten.

Local save measurements: a small PDF saved in 0.19 seconds initially and approximately 0.07 seconds afterward; a 100-page architectural PDF saved in 1.41 seconds initially and 1.03–1.15 seconds afterward. Times depend on document size, storage and system load.
