# Invert viewer mode

The bottom status bar now has an Invert toggle with a half-filled circle icon, a blue active state, and an accessible description. View > Invert invokes the same action. It is disabled without a PDF or during document processing.

Invert uses AppKit's Core Image content filter on the PDF view. It never changes PDF pages, annotations, resources, page geometry, or save payloads. The toolbar and sidebar are outside the filtered view. The preference lasts for the current viewer session and continues across page navigation; starting the app returns to normal colors.

Validation:

- 128 regression tests completed, 15 optional tests skipped, zero failures.
- Native UI verification on a private copy of a nine-page architectural overlay: toggling visibly inverts the page, keeps surrounding controls unchanged, remains active on the next page, and toggling again restores normal colors.
- Regression coverage checks the toggle's enabled and selected states, View-menu checkmark, unchanged original page rendering and geometry, unchanged zoom, and no unsaved markup state after toggling.
- Existing save tests completed in approximately 0.06–0.10 seconds on their small fixtures.

The isolated local QA bundle is `tmp/invert-ui/Drawbridge Invert Test.app`. No installed application was replaced and no new GitHub release was issued for this change.
