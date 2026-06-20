# Review fixes — work log

Workspace doc for the review-driven fix pass (delete once merged). Tracks what
changed and what's left for you.

## Structural change
- Pure, framework-free logic (`Band`, `ChannelPlan`, `BSS`, `ChannelLoad`,
  `Analysis`, `SortKey`/`sortNets`, padding, width/colour helpers) moved to
  `Sources/wifiscan/Core.swift`. `main.swift` keeps CoreWLAN/CoreLocation, the
  TUI, the out-of-process helper, and the entrypoint. Same module — no `import`
  needed; `make`/`swiftc` compiles both files into one binary.
- Tests live in `Tests/CoreTests.swift`, compiled with plain `swiftc` (no
  XCTest, so they run under Command Line Tools only). `make test` runs them.

## Fixed (High → Medium)
- [x] Signal-bar column: dropped `padTo` on the ANSI-coloured bar (was truncating
      mid-escape → colour bleed + misalignment in both colour and `--no-color`).
- [x] Scan helper: deadline + `terminate()` watchdog; `scanning` cleared via
      `defer` so a hung helper can no longer wedge all future scans.
- [x] `--diag`/`--json`/`--once` now run with Wi-Fi off (power guard gates only
      the interactive TUI); `--json` emits `[]`.
- [x] Channel 165 added to 5 GHz non-DFS recommendation candidates.
- [x] `relaunchInTerminal`: proper AppleScript escaping (`\` then `"`) + shell.
- [x] Bare `swiftc` build (no `.app`): clear error instead of a silent broken scan.
- [x] Bad `--interval`/`--sort` values now error to stderr (exit 2) instead of
      silently using defaults.
- [x] Display-width-aware padding (CJK/emoji SSIDs); header lines clipped to
      terminal width.
- [x] Redraw only when the frame actually changes; per-line clear instead of a
      full-screen wipe every ~100 ms (kills flicker + idle CPU).
- [x] Layout off-by-one: the bottom-padding calc didn't reserve the separator
      line, so the frame ran one row tall and `prefix(rows)` clipped the footer
      (keymap help). Now counts separator + recommendations + footer.
- [x] Unit tests for the channel/bonding/congestion/sort core.

## Fixed (Low / nits / docs)
- [x] hidden-vs-redacted: permission warning keyed off helper Location status,
      not "all SSIDs empty".
- [x] Cached interface/SSID (no live CoreWLAN call per frame).
- [x] Auto-refresh cadence no longer counts skipped (in-flight) ticks.
- [x] `_NSGetExecutablePath` buffer retry; 6 GHz ch-2 guard; helper non-zero exit
      on write failure + RunLoop watchdog; stale temp-file sweep at startup.
- [x] `--help` and footer synced with real flags/keys.

## Flag surface trimmed (per request — fundamentals only)
Kept: `--once`, `--json`, `--diag`, `--help`/`-h`. Dropped: `--no-color`
(→ automatic: off when piped/redirected or `NO_COLOR` set, on in a terminal),
`--no-relaunch`, `--interval`, `--sort` (all adjustable live in the TUI),
`--version`, and the `--bench` diagnostic (was a testing aid). Internal
`--scan-json`/`--scan-daemon` remain (never typed; reached only via `open`).
- [x] POSIX-locale time formatter; graph leading-blank row removed; ESC-sequence
      drain in `readKey`; 0-AP rows show `—` not the `-127` sentinel.
- [x] Info.plist: dropped deprecated `NSLocationUsageDescription`.
- [x] README: Swift badge, colour key, footer, flag table, JSON key order, version.

## #7 persistent scan helper — DONE and tested live
Replaced the per-refresh `open` spawn with ONE long-lived helper
(`--scan-daemon`), launched via `open` (still a LaunchServices app session, so
SSIDs reveal), driven over a small atomic-file protocol in a per-front-end
control dir, with a heartbeat so the helper self-exits if the front-end dies. The
old `--scan-json` one-shot remains as a fallback (and keeps any already-running
old front-end working).

Verified on this machine (Apple Silicon / macOS 26, signed `wifiscan-codesign`,
Location authorized):
- SSIDs reveal via the daemon (status authorized; ~27–33 names visible).
- One helper pid serves every scan (bench + a real pty-driven TUI run).
- Warm scans ~90 ms vs the old ~3 s per refresh (no spawn, no re-settle).
- Front-end SIGKILL → orphan daemon self-exits ~16 s later and removes its dir.
- Clean teardown on quit / `--once` / `--diag`; no leaked processes or temp dirs.
- Location grant preserved across the rebuild (same cert → same code identity).

## What I need you to do
1. The new build is already deployed (`make` ran). Quit your old running TUI
   (pid was 7809) and relaunch `wifiscan` to pick up the persistent-helper build.
2. Sanity-check the TUI: table alignment, channel map, SSID reveal, that the
   first refresh takes a few seconds and the rest are instant.
3. `make test` any time to re-run the core unit tests.
4. Delete this file.
