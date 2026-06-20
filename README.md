# wifiscan

A terminal **WiFi survey & channel planner** for modern macOS, driven straight off
**CoreWLAN**. One scan, one screen: every nearby network with its **name, power,
SNR, channel, band, width and security** — sortable on any column, with a live
**channel-congestion map** and a **"cleanest channel" recommendation per band** so
you can pick the best channel for each of your access points. A single
self-contained Swift binary, zero third-party dependencies.

```
 wifiscan   iface en0   connected home-router   location authorized
 networks 22  shown 22   view list   sort Power↓   filter All bands   auto on(6s)   last 19:44
 ────────────────────────────────────────────────────────────────────────────────────────
 SSID                   Chan  Band  Width   dBm  Signal        SNR  Sec
 home-router               6  2.4     20   -34   ██████████      —  WPA2/3
 Neighbour_2G             11  2.4     20   -36   █████████·      —  WPA2/3
 home-router-5G          161  5       80   -45   ████████··     49  WPA2/3
 FiberHome-A1              1  2.4     20   -48   ███████···      —  WPA2/3
 office-mesh              44  5       80   -49   ███████···      —  WPA3
 TP-Link_4F2A              3  2.4     40   -66   ████······      —  WPA2/3
 ISP-WiFi-9021           157  5       80   -73   ███·······      —  WPA2/3
 guest-5G                 36  5       80   -80   ██········      —  WPA2/3
 …
 ────────────────────────────────────────────────────────────────────────────────────────
 Recommended clean channels
   2.4 GHz   ch 1 (3ap)   ch 11 (4ap)   ch 6 (9ap)     only 1/6/11 are non-overlapping
   5 GHz     ch 36 (1ap)  ch 40 (1ap)   ch 44 (2ap)    non-DFS (preferred)
             ch 100 (0ap) ch 104 (0ap)  ch 108 (0ap)   DFS* — cleaner, but may drop on radar
 ────────────────────────────────────────────────────────────────────────────────────────
 [q]uit  [r]escan  [g]raph  [a]uto  [p]ower [s]nr [c]han [n]ame [w]idth s[e]c  [b]and 1/2/6/0  [+/-]interval
```

## Why a custom tool?

On macOS 14.4+ Apple **removed the `airport` CLI**, and there's no maintained free
TUI scanner that returns neighbour RSSI / channel / width. The only API that still
does is **CoreWLAN** (`CWWiFiClient`), which `wifiscan` drives directly in Swift —
so it works on the latest macOS with **no Homebrew, no Python, no `pip`**.

## Build & install

```sh
make            # build wifiscan.app into ~/Applications + a `wifiscan` launcher on ~/.bin
make clean      # remove both
```

`make` compiles an optimised, fully-stripped binary (no debug info) into a signed
`wifiscan.app` bundle and symlinks a `wifiscan` command into `~/.bin`. Make sure
`~/.bin` is on your `PATH`. You can then run `wifiscan` from any terminal, or
**double-click `wifiscan.app`** (it reopens itself in Terminal).

> Requirements: macOS (built & tested on **26 / Apple Silicon**) and the Xcode
> Command Line Tools (`xcode-select --install`) for `swiftc`.

## ⚠️ One-time permission

macOS hides Wi-Fi **SSIDs** unless the scanning app has **Location Services**
permission. `wifiscan` ships as a signed `.app`, so it appears in that list under
**its own name**:

1. Run `wifiscan` (or `wifiscan --diag`) once.
2. **System Settings → Privacy & Security → Location Services** → enable **wifiscan**.
3. Run `wifiscan` again — `wifiscan --diag` should report **`SSIDs visible: N/N`**.

Power, channel, band, width and security all work **without** this — only the
network *names* are gated.

> **Stable permission across rebuilds (optional).** Ad-hoc signing changes the
> app's identity on every `make`, so macOS forgets the grant. To make it stick,
> create a self-signed **Code Signing** certificate once (Keychain Access →
> Certificate Assistant → Create a Certificate, type *Code Signing*) and drop a
> `Makefile.local` with `SIGN := <cert name>` (git-ignored). Then grant once and
> every future build keeps it.

## Usage

```sh
wifiscan                 # interactive TUI (default)
wifiscan --once          # single scan: table + channel map + recommendations
wifiscan --json          # single scan as JSON (pipe into jq, etc.)
wifiscan --diag          # scan + permission diagnostics
wifiscan --sort snr      # initial sort: power|snr|channel|name|band|width|security
wifiscan --interval 10   # auto-refresh seconds (default 6)
wifiscan --no-color      # plain text
wifiscan --help
```

## Keys

| Key | Action | | Key | Action |
|-----|--------|-|-----|--------|
| `q` / `Ctrl-C` | quit | | `p` | sort by power |
| `r` | rescan now | | `s` | sort by SNR |
| `g` / `Tab` | toggle channel-map view | | `c` | sort by channel |
| `a` | toggle auto-refresh | | `n` | sort by name |
| `1` / `2` / `6` | filter to 2.4 / 5 / 6 GHz | | `w` | sort by width |
| `0` | show all bands | | `e` | sort by security |
| `b` | cycle band filter | | `j` / `k` | scroll |
| `+` / `-` | refresh interval | | | press a sort key again to reverse |

## The channel map (`g`)

Per band, each occupied channel gets a power-weighted bar — how much signal energy
actually lands on it — so you can see congestion at a glance:

```
 ▎ 2.4 GHz  (12 networks)
    ch 1    3ap  -48dBm  ███████
    ch 6    9ap  -34dBm  ████████████████████████████████████████
    ch 11   4ap  -36dBm  ██████████

 ▎ 5 GHz  (10 networks)
   ch 36    1ap  -49dBm  ██████████
   ch 161   3ap  -45dBm  ████████████████████████████████████████  DFS
```

## How the recommendation works

- Each AP is mapped to the **frequency span** it actually occupies, accounting for
  20 / 40 / 80 / 160 MHz channel bonding (standard 5 GHz bonded groups; the regular
  6 GHz grid; centre-frequency overlap for 2.4 GHz).
- For each candidate control channel, `wifiscan` sums the **linear power**
  (`10^(RSSI/10)`) of every AP whose span overlaps it — so a strong nearby AP counts
  far more than a weak distant one.
- The channel with the least overlapping energy wins. **2.4 GHz** only ever
  recommends **1 / 6 / 11** (the non-overlapping set). **5 GHz** shows the best
  **non-DFS** channel plus the cleanest **DFS** option (marked `*`; cleaner, but can
  drop out on radar detection). **6 GHz** uses **PSC** channels.

## How it reveals SSIDs (the macOS-26 catch)

This was the hard part. On recent macOS, CoreWLAN redacts SSIDs unless **two**
conditions hold:

1. The app is **authorized for Location Services** (the one-time grant above), and
2. The scan runs in a process launched as a real **app session** (via
   LaunchServices) — *not* a binary spawned directly by a shell. A shell-child
   process gets masked names even when Location is authorized.

So `wifiscan` runs the actual scan in a short-lived **helper instance of itself
launched via `open`** (`open -n -W -g -j wifiscan.app --args --scan-json …`), which
counts as an app session and sees real names, then reads the result back as JSON.
The TUI you interact with is the front-end; each refresh delegates one scan to the
helper. This needs no Apple Developer account and no special entitlement — just the
Location grant. (See the commit history for the full investigation.)

## Known macOS limitations

- **SNR shows `—` for most networks.** macOS only measures the noise floor on the
  channel your radio is currently tuned to, so neighbouring APs report noise as 0.
  RSSI + congestion are the reliable planning signals; SNR is meaningful only for
  your connected channel.
- **No BSSID or country code.** Both are gated behind Apple-*private* entitlements
  (`com.apple.private.corewifi.bssid` / `.countrycode`) that only `airportd` and
  Apple's own tools (Wireless Diagnostics, `wdutil`) carry — a third-party binary
  always gets `nil`, so `wifiscan` doesn't model them. Not needed for channel
  planning.

## Layout

```
Sources/wifiscan/main.swift   the whole program — scan · channel analysis · TUI
Info.plist                    app-bundle metadata + Location-Services usage string
Makefile                      `make` → signed wifiscan.app in ~/Applications + launcher
Package.swift                 SwiftPM manifest (for editors/tooling; `make` uses swiftc)
```

No third-party dependencies — just the system **CoreWLAN**, **CoreLocation** and
**Foundation** frameworks.

Licensed MIT (see `LICENSE`).
