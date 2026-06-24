# Ghostty Fork Sync

Prowl embeds GhosttyKit from `ThirdParty/ghostty`. The submodule points to the `onevcat/ghostty` fork so Prowl can carry small embedded API patches that are not yet upstream.

## Branch Model

- Upstream remote: `https://github.com/ghostty-org/ghostty`
- Fork remote: `git@github.com:onevcat/ghostty.git`
- Per-version patched branches: `release/v<UPSTREAM_TAG>-patched`
- Current patched branch: `release/v1.3.1-patched`

Each patched branch starts at the matching upstream tag and only adds onevcat patches. Do not rewrite an existing patched branch after publishing it.

## Current Patches

Listed in topological order on `release/v1.3.1-patched`. When upgrading to a new
upstream tag, cherry-pick all of them.

1. `76dce319f55db097b2b7ae3cad2f6267475936f0` — `embedded: expose surface child PID`
   - Adds `ghostty_surface_pid(ghostty_surface_t)` to the embedded C API.
   - Returns the local surface child process PID, or `0` when unavailable or exited.
2. `a284127166ce76d872320d7dfa2a5c57268be9de` — `embedded: expose surface foreground process group`
   - Adds `ghostty_surface_foreground_process_group(ghostty_surface_t)` to the
     embedded C API for callers that need the pty's foreground job, not just the
     shell PID.
3. `fe714860c12da41442b63135d09ba80e293b66ad` — `surface: use libc tcgetpgrp for foreground group`
   - Switches the foreground-group lookup from `proc_bsdinfo.e_tpgid` to
     `tcgetpgrp` on the pty fd, which is more reliable when the shell PID
     itself is not the controlling process.
4. `48365577c1ae8e422c0dd90489921f07b9f79171` — `Backport Ghostty text free ABI fix`
   - Backports upstream `ghostty-org/ghostty#12025` before an upstream tag that includes it exists.
   - Keeps the public `ghostty_surface_free_text(ghostty_surface_t, ghostty_text_s*)`
     API shape and fixes the Zig export to accept the unused surface parameter.
   - Drop this patch when upgrading to an upstream tag that contains `4803d58`.
   - This is the commit the submodule currently points at.

## Upgrade To A New Ghostty Tag

```bash
cd ThirdParty/ghostty

git fetch upstream --tags
git fetch onevcat

PREV=v1.3.1
NEXT=v1.3.2

git checkout -b "release/${NEXT}-patched" "${NEXT}"
git cherry-pick "${PREV}..onevcat/release/${PREV}-patched"
git push -u onevcat "release/${NEXT}-patched"

cd ../..
git -C ThirdParty/ghostty checkout "release/${NEXT}-patched"
git add ThirdParty/ghostty
git commit -m "ghostty: bump submodule to ${NEXT}-patched"
make sync-ghostty
make build-app
```

## Prebuilt Artifact Publishing

Prowl's default `make ensure-ghostty` path downloads pinned prebuilt artifacts
from `onevcat/ghostty` before falling back to a local source build.

Release tag format:

```text
xcframework-<ghostty_commit_sha>-prowl-v1
```

Assets:

```text
GhosttyKit.xcframework.tar.gz
GhosttyKit-resources.tar.gz
```

After a local `make sync-ghostty`, package the current artifacts with:

```bash
scripts/package-ghosttykit-artifacts.sh
```

Upload both generated assets to the matching `onevcat/ghostty` release, then add
the emitted manifest line to `scripts/ghosttykit-checksums.txt` in Prowl. The
manifest is reviewed source of truth for downloaded artifact integrity.

Verify the prebuilt path from a clean artifact state:

```bash
rm -rf Frameworks/GhosttyKit.xcframework Resources/ghostty Resources/terminfo .ghostty_hash .ghostty_build_stamp
make ensure-ghostty
make build-app
```

## Force Push Policy

Do not force-push `release/v*-patched` branches. If a cherry-pick needs repair, use a temporary fix branch, validate it, then fast-forward the patched branch.

## Build Note

Build GhosttyKit with Xcode 26.3:

```bash
DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer make sync-ghostty
```

Build Prowl itself with the current Xcode, typically Xcode 26.4:

```bash
DEVELOPER_DIR=/Applications/Xcode-26.4.1.app/Contents/Developer make build-app
```
