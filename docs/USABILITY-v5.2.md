# Drawbridge v5.2 validation

Tested the release changes on top of public v5.1, using synthetic PDFs and an isolated QA app.

| Scenario | Result |
| --- | --- |
| macOS light → dark → light appearance inheritance and background refresh | Passed automated window appearance test |
| Pen toolbar and P shortcut; continuous drag drawing | Passed hands-on packaged-app checks |
| Pen color and line width | Passed hands-on and automated checks |
| Pen geometry at 0°, 90°, 180°, 270° page rotation | Passed automated checks |
| Dense fractional-coordinate strokes | Passed automated persistence checks |
| Escape cancellation; delete, undo and redo | Passed automated and hands-on checks |
| Deleted markup disappears immediately | Passed hands-on rendering check |
| Production first save and repeated saves | Passed after fixing an optimizer-sensitive writer call boundary |
| Delete saved stroke, save, quit and reopen | Passed; one remaining live Ink annotation verified in PDF page references |
| PDF structure after save/delete | qpdf validation passed; original source prefix preserved |

Final production regression run: `swift test -c release`, 145 tests executed, 15 skipped, zero failures (30.5 seconds). Skips are existing fixture/native-environment dependent checks; this is engineering QA, not a study with recruited users.

The save verification remains intact. QA found a packaged-production pen-save failure that was absent in the test binary. Keeping the verified writer as a separate call fixed the packaged workflow; repeated saves and reopen were then retested without diagnostic code.

Signed release artifacts are built and notarized by the GitHub release workflow after its production regression gate.
