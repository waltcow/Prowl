# GhosttyKit Prebuilt Artifact Plan

## Goal

Make prebuilt GhosttyKit artifacts the default acquisition path for Prowl, while
keeping local Ghostty source builds available for fork maintenance and emergency
fallbacks.

This is a long-term integration decision for Prowl:

- Prowl pins `ThirdParty/ghostty` to the `onevcat/ghostty` fork.
- Each pinned Ghostty commit may have a matching GitHub Release artifact.
- Normal Prowl builds download and verify that artifact instead of compiling
  Ghostty from Zig source.
- Ghostty source builds remain explicit maintenance operations.

We are intentionally not moving GhosttyKit to a SwiftPM binary target for now.
Prowl's app target currently links `Frameworks/GhosttyKit.xcframework` directly
from the Xcode project and separately bundles `Resources/ghostty` and
`Resources/terminfo`. A Makefile downloader matches that shape with less churn.

## Current State

Prowl currently:

1. Pins `ThirdParty/ghostty` as a submodule to `onevcat/ghostty`.
2. Runs `zig build -Doptimize=ReleaseFast -Demit-xcframework=true -Dsentry=false`
   from the Ghostty submodule.
3. Copies `ThirdParty/ghostty/macos/GhosttyKit.xcframework` to `Frameworks/`.
4. Copies Ghostty runtime resources from `zig-out/share/ghostty` and
   `zig-out/share/terminfo` to `Resources/`.
5. Tracks `.ghostty_hash` and `.ghostty_build_stamp` locally to skip unchanged
   rebuilds.

The expensive part is step 2. Cold worktrees also frequently lack the generated
framework/resources, so `make build-app` currently triggers a full Ghostty build.

## Artifact Model

Publish artifacts from `onevcat/ghostty` GitHub Releases.

Release tag format:

```text
xcframework-<ghostty_commit_sha>-prowl-v1
```

Assets:

```text
GhosttyKit.xcframework.tar.gz
GhosttyKit-resources.tar.gz
```

`GhosttyKit-resources.tar.gz` contains exactly:

```text
ghostty/
terminfo/
```

The Prowl repository stores a reviewed checksum manifest:

```text
scripts/ghosttykit-checksums.txt
```

Each non-comment line uses:

```text
<ghostty_commit_sha> <xcframework_sha256> <resources_sha256>
```

The commit SHA is the gitlink recorded in Prowl, not "whatever the submodule
working tree currently reports". This allows cold worktrees to download
artifacts before the heavy Ghostty submodule is initialized.

## Build Flow

`make ensure-ghostty`:

1. Read the pinned Ghostty gitlink with:

   ```bash
   git rev-parse HEAD:ThirdParty/ghostty
   ```

2. If `Frameworks/GhosttyKit.xcframework`, `Resources/ghostty`, and
   `Resources/terminfo` already exist and `.ghostty_hash` matches, do nothing.
3. If a checksum entry exists, download both release assets for the pinned SHA.
4. Verify SHA256 for both assets.
5. Validate archive shape before extraction.
6. Extract into `Frameworks/` and `Resources/`.
7. Refresh `libghostty.a`'s archive index with `xcrun ranlib`.
8. Write `.ghostty_hash` and `.ghostty_build_stamp`.
9. If no pinned artifact exists or the download is unavailable, fall back to the
   existing local Ghostty build.

Checksum mismatch or unsafe archive shape is a hard failure. That indicates a
broken or suspicious artifact and should not silently fall back.

`make sync-ghostty`:

- Remains the explicit "force local rebuild from source" command.
- Requires the Ghostty submodule to be initialized.
- Continues to clear Xcode DerivedData after rebuilding.

## Publishing Flow

For a new Ghostty commit:

1. Build from source on a machine with the required Xcode:

   ```bash
   DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer make sync-ghostty
   ```

2. Package artifacts:

   ```bash
   scripts/package-ghosttykit-artifacts.sh
   ```

3. Create the matching `onevcat/ghostty` release and upload both assets.
4. Add the emitted checksums to `scripts/ghosttykit-checksums.txt`.
5. Verify a clean acquisition path:

   ```bash
   rm -rf Frameworks/GhosttyKit.xcframework Resources/ghostty Resources/terminfo .ghostty_hash .ghostty_build_stamp
   make ensure-ghostty
   make build-app
   ```

## CI Flow

The macOS setup action should:

1. Use the pinned gitlink SHA for its cache key.
2. Restore the existing GitHub Actions cache when available.
3. Run `make ensure-ghostty` on cache miss.
4. Continue caching generated framework/resources and marker files.

This keeps CI deterministic while making cache misses much faster.

## Risks

- **Artifact drift:** mitigated by pinned tag names and checked-in SHA256 values.
- **Unsafe archive extraction:** mitigated by validating tar entries and archive
  roots before extraction.
- **Missing artifact for a new Ghostty commit:** local source build remains the
  fallback, so development is not blocked.
- **Stale module caches after header changes:** `ensure-ghostty` clears
  DerivedData when the pinned Ghostty SHA changes, preserving the current
  behavior.

## Non-Goals

- No SwiftPM binary target migration in this phase.
- No dependency on upstream Ghostty release assets.
- No "latest release" behavior.
- No committed generated `GhosttyKit.xcframework` or runtime resources.

## Implementation Checklist

- Add artifact checksum manifest.
- Add archive validator.
- Add artifact packaging script.
- Add artifact ensure/download script.
- Wire `make ensure-ghostty` to the downloader with local build fallback.
- Update CI setup action to use the downloader.
- Update Ghostty fork sync documentation.
- Build/package/upload current `48365577c1ae8e422c0dd90489921f07b9f79171`
  artifact.
- Verify `make ensure-ghostty` from missing local artifacts.
- Verify `make build-app`.
