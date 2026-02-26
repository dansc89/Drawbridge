# Drawbridge User Manual (Minimal)

Drawbridge is a macOS PDF markup and takeoff app for design and construction workflows.

## 1. Start

1. Open Drawbridge.
2. Open an existing PDF (`File > Open PDF...`) or create a new one (`File > New...`).
3. Choose a tool from the toolbar and start marking up.

## 2. Main Areas

- `Navigation` (left): page thumbnails + bookmarks.
- `Canvas` (center): live PDF markup area.
- `Tool/Layer Settings` (right or bottom controls): style, snap, layer visibility/color.
- `Status Bar`: active tool, page, zoom, scale, and active layer.

## 3. Toolset

- `Select`: move/resize/edit markups.
- `Grab`: capture linework/snapshots from a PDF region.
- `Pen`, `Highlighter`
- `Line`, `Polyline`, `Polygon`, `Arrow`
- `Cloud`, `Rectangle`, `Ellipse`
- `Text`, `Callout`
- `Area`, `Measure`, `Calibrate`

Tip: polygon and line markups support node/endpoint editing in selection mode.

## 4. Layers (Global Snapshot Control)

Layers are designed for grabbed/pasted snapshot linework and update globally across the document.

- Default layer set includes `DEFAULT`, `ARCHITECTURAL`, `STRUCTURAL`, `MECHANICAL`, `ELECTRICAL`, `PLUMBING`, `CIVL`, `LANDSCAPE`.
- `Eye` icon per layer: show/hide that layer.
- `Color well` per layer: set global layer color (all snapshots on that layer update across all pages).
- `DEFAULT` layer: preserves original colors (no forced tint).

Assigning layers:

- During grab paste flow: choose a layer when prompted.
- On existing snapshot markup: right-click and use `Assign Layer…`.

## 5. Grab + Paste Workflow

1. Choose `Grab`.
2. Drag a region to capture snapshot linework.
3. Paste using normal paste or `Cmd+Shift+V` (paste in place).
4. Assign to a target layer.
5. Use layer color controls to globally recolor consultant linework.

## 6. Bookmarks + Auto Sheet Naming

Use `Markups > Auto-Generate Sheet Names/Bookmarks…`.

Flow:

1. Prompt asks whether to delete existing bookmarks and page names first.
2. Capture sequence runs for sheet number/title.
3. Apply generated bookmark/page naming results.

## 7. Scale + Takeoff

- `Calibrate` to set drawing scale from known distance.
- `Measure` for linear dimensions.
- `Area` for area takeoff.
- Use `View > Set Drawing Scale...` and page scale lock tools for multi-page sets.

## 8. Search + Export

- `Cmd+F`: unified search (document text + markup text).
- `File > Save As PDF...`: export a new PDF copy.
- `File > Export Markups CSV...`: export markup data.

## 9. Shortcuts

- Tool shortcuts are customizable: `Drawbridge > Keyboard Shortcuts…`.
- Useful defaults:
- `Cmd+Shift+V`: paste grab snapshot in place
- `Cmd+F`: search
- `Cmd+S`: save
- `Cmd+Shift+S`: Save As PDF

## 10. Cloud Sync Backend (Optional)

Drawbridge includes an optional backend for:

- Username/password accounts
- Project/document permissions
- Upload/download
- Session-based realtime sync

See backend setup: `Backend/README.md`.
