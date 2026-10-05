Drawbridge v4.6 improves markup save speed and reliability, and fixes a blank viewer when switching from a larger drawing set to a smaller PDF.

Markup and navigation changes now share one PDF object update, with faster preservation checks and no redundant containing-folder flush that could stall saving. Saves still use verified output, file synchronization, and atomic replacement. Original page content streams, page bounds, and rotation remain unchanged.

The usability review covers the available markup tools and shortcuts, active-tool highlighting, inline text, selection/editing, undo/redo, navigation, sheet lookup, search, bookmarks, hyperlinks, flatten/unflatten, reduction, and save/reopen. Regression tests and real drawing fixtures include rotated pages and preservation checks. A real 14-page mechanical set completed the application save in 2.92 seconds; a 100-page/5,000-annotation synthetic stress test completed five save cycles averaging 1.35 seconds. Timings depend on PDF complexity and storage; these are measured examples, not a universal save-time guarantee.

The release workflow now runs the full default regression suite before packaging. The app and DMG are Developer ID signed, notarized, and stapled.
