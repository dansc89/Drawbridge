# Drawbridge Development

Technical scripts and workflows for local development and release management.

## Run In Dev Mode

```bash
cd /Users/danielnguyen/Drawbridge
swift run
```

## Run Backend (Cloud Sync)

```bash
cd /Users/danielnguyen/Drawbridge/Backend
cp .env.example .env
npm install
npm run start
```

Backend docs:

`/Users/danielnguyen/Drawbridge/Backend/README.md`

## Build A Launchable `.app` Bundle

```bash
cd /Users/danielnguyen/Drawbridge
./Scripts/package-app.sh
```

Output:

`/Users/danielnguyen/Drawbridge/dist/Drawbridge.app`

Launch:

```bash
open /Users/danielnguyen/Drawbridge/dist/Drawbridge.app
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
cd /Users/danielnguyen/Drawbridge
export DRAWBRIDGE_CODESIGN_IDENTITY="Developer ID Application: <Your Name> (<TEAMID>)"
./Scripts/package-app.sh
```

### 3) Store notarization profile (one-time)

```bash
cd /Users/danielnguyen/Drawbridge
./Scripts/setup-notary-profile.sh drawbridge-notary <apple-id-email> <TEAMID> <app-specific-password>
```

### 4) Notarize + staple app (and optional DMG)

App only:

```bash
cd /Users/danielnguyen/Drawbridge
export DRAWBRIDGE_NOTARY_PROFILE="drawbridge-notary"
./Scripts/notarize-release.sh dist/Drawbridge.app
```

App + DMG:

```bash
cd /Users/danielnguyen/Drawbridge
export DRAWBRIDGE_NOTARY_PROFILE="drawbridge-notary"
./Scripts/notarize-release.sh dist/Drawbridge.app dist/Drawbridge-vX.Y.Z.dmg
```

### 5) Verify Gatekeeper acceptance

```bash
spctl -a -vv dist/Drawbridge.app
xcrun stapler validate dist/Drawbridge.app
```

## Optional Install To Applications

```bash
cp -R /Users/danielnguyen/Drawbridge/dist/Drawbridge.app /Applications/
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
cd /Users/danielnguyen/Drawbridge
CHECKPOINT_LABEL="stable-window-fix" ./Scripts/package-app.sh
```

List checkpoints:

```bash
cd /Users/danielnguyen/Drawbridge
./Scripts/checkpoint.sh list
```

Restore app checkpoint:

```bash
cd /Users/danielnguyen/Drawbridge
./Scripts/checkpoint.sh restore <checkpoint-name>
```

Restore source snapshot:

```bash
cd /Users/danielnguyen/Drawbridge
./Scripts/checkpoint.sh restore-source <checkpoint-name>
```

## Sync To Google Drive

Safe sync (no deletes in target):

```bash
cd /Users/danielnguyen/Drawbridge
./Scripts/sync-to-gdrive.sh
```

Mirror sync (deletes removed local files from target):

```bash
cd /Users/danielnguyen/Drawbridge
./Scripts/sync-to-gdrive.sh /Users/danielnguyen/Drawbridge --mirror
```

## GitHub Releases

Release workflow publishes macOS artifacts when pushing a version tag:
- `Drawbridge-<tag>.dmg`
- `Drawbridge-<tag>.zip`

Create and publish a release:

```bash
cd /Users/danielnguyen/Drawbridge
git tag v0.1.4
git push origin v0.1.4
```

Standard local publish command (ensures DMG is uploaded to the release):

```bash
cd /Users/danielnguyen/Drawbridge
./Scripts/publish-release.sh v0.1.4 dist/Drawbridge-v0.1.4.dmg
```

Latest release URL:

`https://github.com/dansc89/Drawbridge/releases/latest`

## Stress Harness

Generate and benchmark a synthetic heavy PDF:

```bash
cd /Users/danielnguyen/Drawbridge
./Scripts/run-stress.sh 300 100 /Users/danielnguyen/Drawbridge/dist/stress/Drawbridge-Stress.pdf
```

Args:
- first: page count
- second: markups per page
- third: output PDF path (optional)
- fourth: benchmark iterations (optional, default `1`; values `>1` print avg/p50/p95/max)

Example with benchmark summary:

```bash
cd /Users/danielnguyen/Drawbridge
./Scripts/run-stress.sh 300 100 /Users/danielnguyen/Drawbridge/dist/stress/Drawbridge-Stress.pdf 5
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
cd /Users/danielnguyen/Drawbridge
DRAWBRIDGE_PERF=1 swift run
```

Log path:

`~/Library/Application Support/Drawbridge/Logs/performance.log`

## Nightly Stress Suite

Run manually:

```bash
cd /Users/danielnguyen/Drawbridge
./Scripts/nightly-stress-suite.sh
```

Install launchd automation (daily 2:00 AM):

```bash
cd /Users/danielnguyen/Drawbridge
./Scripts/install-nightly-stress-launchd.sh
```

## Compatibility Gate (Internal)

Run backend-only compatibility and save-performance validation:

```bash
cd /Users/danielnguyen/Drawbridge
./Scripts/run-compat-gate.sh smoke
```

Standard release-grade profile:

```bash
cd /Users/danielnguyen/Drawbridge
./Scripts/run-compat-gate.sh standard
```

Notes:
- This is non-UI validation only (no user-facing prompts or controls).
- Gate fails on persistence regressions or p95 save-write threshold regressions.

## Link Compatibility Variant Export (Internal)

Generate backend-only hyperlink destination variants for external viewer A/B checks:

```bash
cd /Users/danielnguyen/Drawbridge
./Scripts/export-link-compat-variants.sh /absolute/path/to/file.pdf /absolute/path/to/output-dir
```

Output files:
- `*.links-fit.pdf`
- `*.links-fith.pdf`
- `*.links-fitr.pdf`
- `*.links-xyz0.pdf`
