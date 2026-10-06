Drawbridge v5.0 makes small markup saves substantially faster on large drawing sets, adds a screen-only Invert mode, and improves annotation placement and toolbar alignment.

- Markup saves append only changed annotation objects and reuse existing appearances. Background preparation during opening avoids repeating whole-document inspection on every save. Original PDF content streams, graphics, page boxes and rotations remain intact.
- Six new vector markups on a 155 MB, 124-page drawing set saved through the application in 0.56, 0.54 and 0.47 seconds in local production tests. If preparation is incomplete, the first save still needs an initial inspection; network and file-provider storage can affect performance.
- Invert changes PDF colors on screen without changing saved or printed colors.
- Line and arrow tools support two-click placement: choose L or A, click the start point, then click the endpoint.
- Annotation controls are centered relative to the full app window.
- Saving while adding more markups preserves the newer unsaved edits and correctly advances the saved source version. External file changes are checked before committing.

Validation: 135 regression tests executed, 15 optional tests skipped, zero failures. Coverage includes all seven markup tools, text, rotated/cropped pages, repeated saving, external edits, imported annotations, navigation, Flatten, Unflatten and Reduce. Independent checks preserved all 124 original page content streams, page geometry and rotations, with matching original-content rendering on sampled pages. Packaged toolbar and keyboard rectangle saves passed after an explicit production rebuild.
