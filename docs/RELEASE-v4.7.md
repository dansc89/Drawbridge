Drawbridge v4.7 fixes markup save failures caused by copied annotations sharing an identifier and reduces the time needed to verify saves.

- Keeps document switching and closing blocked until an active save or PDF operation finishes.
- Avoids rescanning every annotation while typing inline text.
- Preserves original page content and geometry during annotation-only saves.
- Retains the active-tool highlight, Bluebeam-style tool shortcuts, inline text editing and polygon vertex controls.

Validation: 117 regression tests passed with nine optional corpus tests skipped. All seven markup tools were manually created, saved and verified visually in Apple Preview. Flatten, Unflatten and Reduce passed through the toolbar with identical rendered pixels and preserved markup records, text, links and page geometry. A 100-page architectural fixture saved in 1.37 seconds locally; timing varies with document and storage.
