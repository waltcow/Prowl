# Active Agents Panel Task Log

## 2026-05-09

### Scope

- Implement Phase 0, Phase 1, and Phase 2 from `doc-onevcat/plans/2026-05-09-active-agents-panel-plan.md`.
- Keep commits small enough to audit.
- Maintain high test coverage for pure detection logic and state transitions.

### Progress

- Started from branch `feat/active-agents-panel`.
- Initial worktree was clean; only existing branch commit was the implementation plan.
- Confirmed Xcode uses file-system synchronized root groups, so new Swift source/test files under `supacode/` and `supacodeTests/` are picked up automatically.

### Decisions And Notes

- Pure detection logic is implemented first with tests before wiring, because it is the most important stable contract for later UI iteration.
- Created `onevcat/ghostty` and pushed `release/v1.3.1-patched` with `ghostty_surface_pid`.
- `make sync-ghostty` fails under Xcode 26.4.1 before compiling Ghostty sources because Zig 0.15.2 cannot link the native build runner. Re-running with `DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer` succeeds.
- Added Active Agents reducer/UI wiring and terminal detection loop. `GhosttySurfaceBridge.childPID()` uses `dlsym` so the app still compiles before the patched GhosttyKit binary is rebuilt; after rebuild, the exported `ghostty_surface_pid` symbol is used automatically.
- The Active Agents panel height is persisted globally but visually capped by the sidebar container height, reserving at least 200 pt for the repository list.
- Agent display names intentionally use short command-style lowercase tokens (`pi`, `claude`, `codex`, `kimi`, etc.) because the panel is a compact terminal-status surface, not product branding.
- Screen heuristics are exposed as `DetectedAgent.detectState(in:)` so detection behavior stays attached to the identified agent while the per-agent detectors remain private pure functions.
- The Active Agents footer toggle uses stable `person.crop.rectangle.stack` / `person.crop.rectangle.stack.fill` SF Symbols after the previous bottom-panel symbol rendered empty in the hidden state on the tested system.
- Added DEBUG-only agent detection diagnostics for child PID lookup, foreground process group, candidate processes, identified/retained agent, raw screen state, and stabilized state after manual testing showed no agents appearing in the panel.
- Added `ghostty_surface_foreground_process_group` to the Ghostty fork and switched Swift detection to prefer Ghostty's pty foreground process group over `proc_bsdinfo.e_tpgid`, which was nil for the shell PID during manual testing.

### Verification

- `xcodebuild test -project supacode.xcodeproj -scheme supacode -destination "platform=macOS" -only-testing:supacodeTests/DetectedAgentTests -only-testing:supacodeTests/AgentClassifierTests -only-testing:supacodeTests/ScreenHeuristicsTests -only-testing:supacodeTests/PaneAgentStateTests -only-testing:supacodeTests/ActiveAgentsFeatureTests -only-testing:supacodeTests/ProcessDetectionSmokeTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -skipMacroValidation 2>&1 | xcsift -f toon -w` passed 19 tests.
- `make check` passed after keeping the `pi` agent case name and disabling SwiftLint's `identifier_name` rule on that enum case only.
- `xcodebuild -project supacode.xcodeproj -scheme supacode -configuration Debug build -skipMacroValidation CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" 2>&1 | xcsift -f toon -w` passed.
- `DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer make sync-ghostty` completed successfully.
- `nm -gU Frameworks/GhosttyKit.xcframework/macos-arm64_x86_64/libghostty.a | rg 'ghostty_surface_(pid|process_exited)'` finds both `_ghostty_surface_pid` and `_ghostty_surface_process_exited`.
- `make build-app` completed successfully after building the app and embedded CLI.
- `make test` passed 1038 tests with GhosttyKit already up-to-date.
