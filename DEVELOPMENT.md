# Drawbridge Development

Technical scripts and workflows for local development and release management.

## Run In Dev Mode

```bash
cd /Users/danielnguyen/Drawbridge
swift run
```

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
