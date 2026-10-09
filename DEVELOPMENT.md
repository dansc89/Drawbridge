# Drawbridge Development

Technical scripts and workflows for local development and release management. Replace `/path/to/Drawbridge` with your checkout location. Keep client PDFs, logs, and credentials outside tracked files.

The optional `Backend/` prototype is separate from the released macOS app and is not a production collaboration service.

## Run In Dev Mode

```bash
cd /path/to/Drawbridge
swift run
```

## Optional Experimental Backend

```bash
cd /path/to/Drawbridge/Backend
cp .env.example .env
npm install
npm run start
```

Backend docs:

[Backend instructions](Backend/README.md)

## Build A Launchable `.app` Bundle

```bash
cd /path/to/Drawbridge
./Scripts/package-app.sh
```

Output:

`/path/to/Drawbridge/dist/Drawbridge.app`

Launch:

```bash
open /path/to/Drawbridge/dist/Drawbridge.app
```

## Trusted macOS Distribution (Sign + Notarize)

### 1) Confirm Developer ID identity is installed

```bash
security find-identity -v -p codesigning
```

You need a `Developer ID Application:` identity in the output.

Quick local diagnostic:

```bash
./Scripts/check-signing-setup.sh
```

### 2) Build with Developer ID signing

```bash
cd /path/to/Drawbridge
export DRAWBRIDGE_CODESIGN_IDENTITY="Developer ID Application: <Your Name> (<TEAMID>)"
./Scripts/package-app.sh
```

### 3) Store notarization profile (one-time)

```bash
cd /path/to/Drawbridge
./Scripts/setup-notary-profile.sh drawbridge-notary <apple-id-email> <TEAMID>
```

### 4) Notarize + staple app (and optional DMG)

App only:

```bash
cd /path/to/Drawbridge
export DRAWBRIDGE_NOTARY_PROFILE="drawbridge-notary"
./Scripts/notarize-release.sh dist/Drawbridge.app
```

App + DMG:

```bash
cd /path/to/Drawbridge
export DRAWBRIDGE_NOTARY_PROFILE="drawbridge-notary"
./Scripts/notarize-release.sh dist/Drawbridge.app dist/Drawbridge-vX.Y.dmg
```

### 5) Verify Gatekeeper acceptance

```bash
spctl -a -vv dist/Drawbridge.app
xcrun stapler validate dist/Drawbridge.app
```

## Optional Install To Applications

```bash
cp -R /path/to/Drawbridge/dist/Drawbridge.app /Applications/
open /Applications/Drawbridge.app
```

## Iterative Checkpoints

Each `./Scripts/package-app.sh` run creates:
- `dist/checkpoints/apps/<timestamp>-<git-tag-or-label>.app`
- `dist/checkpoints/src/<timestamp>-<git-tag-or-label>.tar.gz`
- `dist/checkpoints/latest.app`

If no label is provided, the current Git tag is used.

Optional labeled checkpoint:

```bash
cd /path/to/Drawbridge
CHECKPOINT_LABEL="stable-window-fix" ./Scripts/package-app.sh
```

List checkpoints:

```bash
cd /path/to/Drawbridge
./Scripts/checkpoint.sh list
```

Restore app checkpoint:

```bash
cd /path/to/Drawbridge
./Scripts/checkpoint.sh restore <checkpoint-name>
```

Restore source snapshot:

```bash
cd /path/to/Drawbridge
./Scripts/checkpoint.sh restore-source <checkpoint-name>
```

## Sync To Google Drive

Safe sync (no deletes in target):

```bash
cd /path/to/Drawbridge
DRAWBRIDGE_SYNC_ROOT="/path/to/Google Drive/My Drive" ./Scripts/sync-to-gdrive.sh
```

Mirror sync (deletes removed local files from target):

```bash
cd /path/to/Drawbridge
DRAWBRIDGE_SYNC_ROOT="/path/to/Google Drive/My Drive" ./Scripts/sync-to-gdrive.sh /path/to/Drawbridge --mirror
```

## GitHub Releases

Release workflow publishes macOS artifacts when pushing a version tag:
- `Drawbridge-<tag>.dmg`
- `Drawbridge-<tag>.zip`

Create and publish a release:

```bash
cd /path/to/Drawbridge
git tag vX.Y
git push origin vX.Y
```

Standard local publish command (ensures DMG is uploaded to the release):

```bash
cd /path/to/Drawbridge
./Scripts/publish-release.sh vX.Y dist/Drawbridge-vX.Y.dmg
```

Latest release URL:

`https://github.com/dansc89/Drawbridge/releases/latest`

## Stress Harness

Generate and benchmark a synthetic heavy PDF:

```bash
cd /path/to/Drawbridge
./Scripts/run-stress.sh 300 100 /path/to/Drawbridge/dist/stress/Drawbridge-Stress.pdf
```

Args:
- first: page count
- second: markups per page
- third: output PDF path (optional)
- fourth: benchmark iterations (optional, default `1`; values `>1` print avg/p50/p95/max)

Example with benchmark summary:

```bash
cd /path/to/Drawbridge
./Scripts/run-stress.sh 300 100 /path/to/Drawbridge/dist/stress/Drawbridge-Stress.pdf 5
```

Index snapshot path:

`~/Library/Application Support/Drawbridge/MarkupIndexSnapshots`

## Performance Reliability Controls

In app menu:

`Drawbridge -> Performance Settings…`

Controls:
- adaptive markup index cap
- max indexed markups in memory
- main-thread watchdog threshold and enable/disable

Watchdog log path:

`~/Library/Application Support/Drawbridge/Logs/watchdog.log`

Optional performance event log:

```bash
cd /path/to/Drawbridge
DRAWBRIDGE_PERF=1 swift run
```

Log path:

`~/Library/Application Support/Drawbridge/Logs/performance.log`

## Nightly Stress Suite

Run manually:

```bash
cd /path/to/Drawbridge
./Scripts/nightly-stress-suite.sh
```

Install launchd automation (daily 2:00 AM):

```bash
cd /path/to/Drawbridge
./Scripts/install-nightly-stress-launchd.sh
```

## Compatibility Gate (Internal)

Run backend-only compatibility and save-performance validation:

```bash
cd /path/to/Drawbridge
./Scripts/run-compat-gate.sh smoke
```

Standard release-grade profile:

```bash
cd /path/to/Drawbridge
./Scripts/run-compat-gate.sh standard
```

Notes:
- This is non-UI validation only (no user-facing prompts or controls).
- Gate fails on persistence regressions or p95 save-write threshold regressions.

## Link Compatibility Variant Export (Internal)

Generate backend-only hyperlink destination variants for external viewer A/B checks:

```bash
cd /path/to/Drawbridge
./Scripts/export-link-compat-variants.sh /absolute/path/to/file.pdf /absolute/path/to/output-dir
```

Output files:
- `*.links-fit.pdf`
- `*.links-fith.pdf`
- `*.links-fitr.pdf`
- `*.links-xyz0.pdf`

## Recovered-font hyperlink placement (v3.8)

Recovered AutoCAD text is used only to locate search regions. `VisualSheetReferenceLocator` positions link activation rectangles from exact OCR word bounds in original page pixels. Overlapping regions render once; a missed reference gets a wider isolated crop retry. Destination identifiers remain restricted to literal OCR sheet numbers.

Validation: native app fixture produced and saved all 31 expected references across an 11-page rotated civil PDF. Decoded drawing streams, resource trees, page boxes, and rotations remained unchanged; the saved file did not grow. `CivilLinkBoundsTests` accepts `DRAWBRIDGE_CIVIL_FIXTURE` and `DRAWBRIDGE_RUN_VISION_TESTS=1` in a native Vision-capable environment. Terminal CI skips this fixture test; the native fixture was validated locally before release.

## Bookmark progress and OCR numeric format checks (v3.9)

Bookmark generation reports the current page, field being read, OCR verification pass, nearby search attempts, completed pages, identified numbers and elapsed time. The progress bar reflects completed pages. Review/apply stages have explicit descriptions.

`SheetReferencePolicy.reconcileOCRNumbers` resolves OCR O/0 and I/L/1 confusion only in numeric positions of a strongly supported format, with ordered OCR anchors before and after the sheet. It does not consult saved labels or bookmarks, change reference matching, or allow ordinal destinations. This correction is shared by bookmarking and hyperlink destination scanning.

Local native validation read 43 general-sheet title blocks in a 99-page architectural PDF, recovering three missing destinations. Saved links reopened at pages 7, 9 and 12. All 99 drawing streams, resource trees, boxes and rotations remained unchanged; three added link annotations grew the file by 1,071 bytes. `OCRNumericFormatTests` covers supported correction, insufficient evidence, legitimate letter prefixes, and ordinary numeric tokens.

## Private corpus fixtures

`PDFBookmarkCorpusTests` accepts `DRAWBRIDGE_BOOKMARK_DESKTOP_FIXTURES` pointing to a private folder containing `project-a/mechanical.pdf`, `project-a/landscape.pdf`, `project-b/electrical.pdf`, and `project-b/landscape.pdf`. The separate `DRAWBRIDGE_BOOKMARK_FIXTURES` folder contains `MECH.pdf`, `ARCH.pdf`, `Survey.pdf`, and `SCALE TEST.pdf`. Copy or symlink your permitted local fixtures to these neutral names; never commit them. Other optional test environment variable names are retained for compatibility, but their values stay local.

Before publishing, run `python3 Scripts/check-public-files.py` and `gitleaks git . --log-opts="--all" --redact`. Public CI repeats both checks.

## Local publication checks

Enable the repository pre-push checks with `git config core.hooksPath .githooks` after installing Gitleaks. These check tracked files, reachable history for private paths/hosts, and credentials before a push. CI repeats the same checks. After any published history rewrite, start from a fresh clone or carefully align existing refs; merging old history can reintroduce removed data.
