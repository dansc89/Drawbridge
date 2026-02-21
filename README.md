# Drawbridge

Native macOS PDF markup and takeoff app built with Swift, AppKit, and PDFKit.

## Run In Dev Mode

```bash
cd /Users/example/Drawbridge
swift run
```

## Build A Launchable .app Bundle

```bash
cd /Users/example/Drawbridge
./Scripts/package-app.sh
```

This creates:

`/Users/example/Drawbridge/dist/Drawbridge.app`

Launch:

```bash
open /Users/example/Drawbridge/dist/Drawbridge.app
```

## Iterative Checkpoints (Rollback Safety)

Every time you run `./Scripts/package-app.sh`, Drawbridge now saves:

- versioned app checkpoint: `dist/checkpoints/apps/<timestamp>-<git-tag-or-label>.app`
- source snapshot: `dist/checkpoints/src/<timestamp>-<git-tag-or-label>.tar.gz`
- `dist/checkpoints/latest.app` pointer

If no label is provided, the current Git tag (for example `v0.1.4`) is used automatically.

Optional label on package:

```bash
cd /Users/example/Drawbridge
CHECKPOINT_LABEL="stable-window-fix" ./Scripts/package-app.sh
```

List checkpoints:

```bash
cd /Users/example/Drawbridge
./Scripts/checkpoint.sh list
```

Restore app checkpoint:

```bash
cd /Users/example/Drawbridge
./Scripts/checkpoint.sh restore <checkpoint-name>
```

Restore source snapshot:

```bash
cd /Users/example/Drawbridge
./Scripts/checkpoint.sh restore-source <checkpoint-name>
```

## Sync To Google Drive

Safe sync (no deletes in Drive target):

```bash
cd /Users/example/Drawbridge
./Scripts/sync-to-gdrive.sh
```

Mirror sync (deletes files in Drive target that were removed locally):

```bash
cd /Users/example/Drawbridge
./Scripts/sync-to-gdrive.sh /Users/example/Drawbridge --mirror
```

## Optional Install To Applications

```bash
cp -R /Users/example/Drawbridge/dist/Drawbridge.app /Applications/
open /Applications/Drawbridge.app
```

## GitHub Releases (One-Click Download)

This repo includes a GitHub Actions workflow that builds release artifacts for macOS when you push a version tag:

- `Drawbridge-<tag>.dmg`
- `Drawbridge-<tag>.zip`

Create and publish a release build:

```bash
cd /Users/example/Drawbridge
git tag v0.1.0
git push origin v0.1.0
```

End users can download the latest release from:

`https://github.com/dansc89/Drawbridge/releases/latest`

## Stress Harness

Generate and benchmark a heavy synthetic PDF:

```bash
cd /Users/example/Drawbridge
./Scripts/run-stress.sh 300 100 /Users/example/Drawbridge/dist/stress/Drawbridge-Stress.pdf
```

Arguments:
- first: number of pages
- second: markups per page
- third: output PDF path (optional)

Index snapshots are persisted at:

`~/Library/Application Support/Drawbridge/MarkupIndexSnapshots`

## Performance Reliability Controls

In Drawbridge menu:

`Drawbridge -> Performance Settings…`

This controls:
- Adaptive markup index cap for very large PDFs
- Maximum indexed markups in-memory
- Main-thread watchdog logging threshold and enable/disable

Watchdog logs:

`~/Library/Application Support/Drawbridge/Logs/watchdog.log`

## Nightly Stress Suite

Run the full 3-tier suite manually:

```bash
cd /Users/example/Drawbridge
./Scripts/nightly-stress-suite.sh
```

Install nightly automation via launchd (runs daily at 2:00 AM):

```bash
cd /Users/example/Drawbridge
./Scripts/install-nightly-stress-launchd.sh
```
