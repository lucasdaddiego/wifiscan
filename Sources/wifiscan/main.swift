// wifiscan — a terminal WiFi survey & channel planner for macOS
//
// Backend: CoreWLAN (CWWiFiClient) — the only API on modern macOS (airport is
// gone since 14.4) that returns RSSI / channel / band / width / security for
// *neighbouring* networks. Requires Location Services permission for the
// responsible app (Terminal/iTerm) to reveal SSIDs.
//
// What macOS will NOT give a third-party binary (and so we don't model): BSSID
// and country code are gated behind Apple-private entitlements
// (com.apple.private.corewifi.bssid / .countrycode) carried only by airportd and
// Apple's own tools, so they always come back nil — there is no point storing them.
//
// noise floor caveat: macOS only measures noise on the channel the radio is
// currently tuned to, so neighbouring BSSes report noise == 0. SNR is therefore
// meaningful only for the channel you're on; we show "—" otherwise and lean on
// RSSI + channel congestion instead.
//
// The pure model / channel-plan / congestion / layout logic lives in Core.swift
// (framework-free, unit-tested). This file holds CoreWLAN/CoreLocation, the TUI,
// the out-of-process scan helper, and the entrypoint.

import CoreLocation
import CoreWLAN
import Darwin
import Foundation

// MARK: - Scanner

final class Scanner {
    let client = CWWiFiClient.shared()
    var iface: CWInterface? { client.interface() }

    var interfaceName: String { iface?.interfaceName ?? "—" }
    var currentSSID: String? { iface?.ssid() }
    var powerOn: Bool { iface?.powerOn() ?? false }

    static let securityChecks: [(CWSecurity, String)] = [
        (.wpa3Enterprise, "WPA3-E"), (.wpa3Personal, "WPA3"), (.wpa3Transition, "WPA3-T"),
        (.wpa2Enterprise, "WPA2-E"), (.wpa2Personal, "WPA2"),
        (.wpaEnterprise, "WPA-E"), (.wpaPersonal, "WPA"),
        (.WEP, "WEP"), (.dynamicWEP, "dWEP"), (.none, "Open"),
    ]

    static func securityLabel(_ n: CWNetwork) -> String {
        var hits: [String] = []
        for (s, label) in securityChecks where n.supportsSecurity(s) { hits.append(label) }
        // Collapse common transition combos for readability.
        if hits.contains("WPA3-T") && hits.contains("WPA2") { return "WPA2/3" }
        if hits.contains("WPA3") { return "WPA3" }
        return hits.first ?? "?"
    }

    func scan() -> (nets: [BSS], error: String?) {
        guard let iface = iface else { return ([], "no Wi-Fi interface") }
        do {
            let raw = try iface.scanForNetworks(withName: nil)
            let nets = raw.map { n -> BSS in
                let ch = n.wlanChannel
                return BSS(
                    ssid: (n.ssid?.isEmpty == false ? n.ssid! : "‹hidden›"),
                    rssi: n.rssiValue,
                    noise: n.noiseMeasurement,
                    channel: ch?.channelNumber ?? 0,
                    band: Band.from(ch?.channelBand.rawValue ?? 0),
                    widthMHz: widthCodeToMHz(ch?.channelWidth.rawValue ?? 0),
                    security: Scanner.securityLabel(n),
                    hidden: (n.ssid?.isEmpty != false)
                )
            }
            return (nets, nil)
        } catch {
            return ([], error.localizedDescription)
        }
    }
}

// MARK: - ANSI

enum Ansi {
    static var enabled = true
    static func wrap(_ s: String, _ code: String) -> String {
        enabled ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s
    }
    static func bold(_ s: String) -> String { wrap(s, "1") }
    static func dim(_ s: String) -> String { wrap(s, "2") }
    static func inverse(_ s: String) -> String { wrap(s, "7") }
    static func fg256(_ s: String, _ c: Int) -> String { wrap(s, "38;5;\(c)") }
    static func bg256(_ s: String, _ c: Int) -> String { wrap(s, "48;5;\(c)") }

    // Signal → colour (256-palette). Logic lives in Core (signalColorCode) so it
    // is unit-testable without this enum.
    static func signalColor(_ rssi: Int) -> Int { signalColorCode(rssi) }

    static func signalBar(_ rssi: Int, width: Int = 10) -> String {
        // Map -90..-30 dBm → 0..width blocks.
        let frac = max(0.0, min(1.0, Double(rssi + 90) / 60.0))
        let filled = Int((frac * Double(width)).rounded())
        let bar = String(repeating: "█", count: filled) + String(repeating: "·", count: width - filled)
        return fg256(bar, signalColor(rssi))
    }
}

/// Clip a possibly-ANSI-coloured string to `cols` visible terminal cells,
/// copying escape sequences verbatim and re-appending a reset if truncated so
/// colour can't bleed past the cut.
func clipAnsi(_ s: String, _ cols: Int) -> String {
    if cols <= 0 { return "" }
    var out = "", width = 0, truncated = false
    var i = s.startIndex
    while i < s.endIndex {
        let c = s[i]
        if c == "\u{1B}" {                       // copy the whole escape sequence
            out.append(c)
            var j = s.index(after: i)
            while j < s.endIndex {
                let e = s[j]; out.append(e); j = s.index(after: j)
                if e.isLetter { break }
            }
            i = j
            continue
        }
        let cw = charDisplayWidth(c)
        if width + cw > cols { truncated = true; break }
        out.append(c); width += cw
        i = s.index(after: i)
    }
    if truncated && Ansi.enabled { out += "\u{1B}[0m" }
    return out
}

// MARK: - Rendering

let timeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")   // fixed HH:mm:ss, locale-independent
    f.dateFormat = "HH:mm:ss"
    return f
}()

struct Layout { var rows: Int; var cols: Int }

func termSize() -> Layout {
    var w = winsize()
    if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &w) == 0, w.ws_row > 0 {
        return Layout(rows: Int(w.ws_row), cols: Int(w.ws_col))
    }
    return Layout(rows: 24, cols: 100)
}

func bandFilterLabel(_ b: Band?) -> String { b?.longLabel ?? "All bands" }

func renderTable(_ nets: [BSS], cols: Int) -> [String] {
    // Column widths (responsive-ish; SSID flexes).
    let wChan = 7, wBand = 5, wWidth = 6, wSig = 6, wBar = 11, wSnr = 5, wSec = 7
    let fixed = wChan + wBand + wWidth + wSig + wBar + wSnr + wSec + 7 // gaps
    let wSSID = max(14, min(32, cols - fixed))
    var out: [String] = []

    let header = [
        padTo("SSID", wSSID), padLeft("Chan", wChan), padTo("Band", wBand),
        padLeft("Width", wWidth), padLeft("dBm", wSig), padTo("Signal", wBar),
        padLeft("SNR", wSnr), padTo("Sec", wSec),
    ].joined(separator: " ")
    out.append(Ansi.bold(Ansi.fg256(header, 250)))

    for n in nets {
        let snrStr = n.snr.map { "\($0)" } ?? "—"
        let widthStr = n.widthMHz > 0 ? "\(n.widthMHz)" : "—"
        let ssid = Ansi.fg256(padTo(n.ssid, wSSID), n.hidden ? 244 : 252)
        let chan = padLeft("\(n.channel)", wChan)
        let band = padTo(n.band.label, wBand)
        let dbm = Ansi.fg256(padLeft("\(n.rssi)", wSig), Ansi.signalColor(n.rssi))
        // signalBar already emits exactly (wBar-1) blocks + 1 space = wBar visible
        // cells, so it is dropped into the row directly — never padded. (padTo on an
        // ANSI string counts escape bytes and would truncate mid-escape.)
        let bar = Ansi.signalBar(n.rssi, width: wBar - 1) + " "
        let snr = padLeft(snrStr, wSnr)
        let sec = padTo(n.security, wSec)
        let line = [ssid, chan, band, padLeft(widthStr, wWidth), dbm, bar, snr, sec]
            .joined(separator: " ")
        out.append(line)
    }
    return out
}

func renderGraph(_ nets: [BSS], cols: Int) -> [String] {
    var out: [String] = []
    let bands: [Band] = [.ghz24, .ghz5, .ghz6]
    var firstBand = true
    for band in bands {
        let inBand = nets.filter { $0.band == band }
        if inBand.isEmpty { continue }
        if !firstBand { out.append("") }      // separator between bands, none before the first
        firstBand = false
        out.append(Ansi.bold(Ansi.fg256("▎ \(band.longLabel)  (\(inBand.count) networks)", 39)))

        // Occupancy per active channel, weighted by overlapping energy.
        let activeChans = Set(inBand.map { $0.channel }).sorted()
        let loads = Analysis.loads(nets, band: band, candidates: activeChans)
        let maxW = max(loads.map { $0.weighted }.max() ?? 1, 1e-9)
        for load in loads.sorted(by: { $0.channel < $1.channel }) {
            let barLen = Int((load.weighted / maxW) * Double(max(0, min(cols - 28, 40))))
            let bar = String(repeating: "█", count: max(load.weighted > 0 ? 1 : 0, barLen))
            let dfs = (band == .ghz5 && ChannelPlan.isDFS(load.channel)) ? Ansi.fg256(" DFS", 244) : ""
            let label = padLeft("ch \(load.channel)", 7)
            let cnt = padLeft("\(load.apCount)ap", 5)
            let strongest = padLeft(load.apCount > 0 ? "\(load.strongest)dBm" : "—", 8)
            let colored = Ansi.fg256(bar, Ansi.signalColor(load.strongest))
            out.append("  \(label) \(cnt) \(strongest)  \(colored)\(dfs)")
        }
    }
    return out
}

func renderRecommendations(_ nets: [BSS]) -> [String] {
    var out: [String] = []
    out.append(Ansi.bold(Ansi.fg256("Recommended clean channels", 47)))

    func fmt(_ recs: [ChannelLoad], band: Band) -> String {
        guard let best = recs.first else { return Ansi.dim("—") }
        // If every candidate is equally empty, none is specifically "best".
        let allClear = recs.allSatisfy { $0.weighted == 0 && $0.apCount == 0 }
        return recs.prefix(3).map { r -> String in
            let dfs = (band == .ghz5 && ChannelPlan.isDFS(r.channel)) ? "*" : ""
            let tag = "ch \(r.channel)\(dfs) (\(r.apCount)ap)"
            return (!allClear && r.channel == best.channel) ? Ansi.bold(Ansi.fg256(tag, 46)) : Ansi.fg256(tag, 250)
        }.joined(separator: "  ")
    }
    func row(_ label: String, _ body: String, _ note: String) {
        out.append("  " + padTo(label, 9) + body + Ansi.dim("  \(note)"))
    }

    if nets.contains(where: { $0.band == .ghz24 }) {
        row("2.4 GHz", fmt(Analysis.recommend(nets, band: .ghz24, candidates: ChannelPlan.cand24), band: .ghz24),
            "only 1/6/11 are non-overlapping")
    }
    if nets.contains(where: { $0.band == .ghz5 }) {
        row("5 GHz", fmt(Analysis.recommend(nets, band: .ghz5, candidates: ChannelPlan.cand5NonDFS), band: .ghz5),
            "non-DFS (preferred)")
        row("", fmt(Analysis.recommend(nets, band: .ghz5, candidates: ChannelPlan.cand5DFS), band: .ghz5),
            "DFS* — cleaner, but may drop on radar")
    }
    if nets.contains(where: { $0.band == .ghz6 }) {
        row("6 GHz", fmt(Analysis.recommend(nets, band: .ghz6, candidates: ChannelPlan.cand6PSC), band: .ghz6),
            "PSC channels")
    }
    return out
}

// MARK: - App

final class App {
    let scanner = Scanner()
    let lock = NSLock()

    // --- fields shared with the background scan thread (guard with `lock`) ---
    var nets: [BSS] = []
    var scanError: String?
    var lastScan: Date?
    var scanning = false
    var scanCount = 0
    var locationStatus = "unknown"
    var ifaceName = "—"            // cached so draw() never calls CoreWLAN per frame
    var connSSID: String?

    // --- UI state (main-thread-confined; not locked) ---
    var sortKey: SortKey = .power
    var ascending = false
    var bandFilter: Band? = nil
    var graphMode = false
    var autoRefresh = true
    var interval: TimeInterval = 6
    var scroll = 0
    var quit = false

    // --- render frame cache (main-thread-confined) ---
    var lastFrame = ""
    var lastCols = 0
    var lastRows = 0

    init() {
        ifaceName = scanner.interfaceName
        connSSID = scanner.currentSSID
    }

    /// Kick off a scan on a background thread. Returns false if one is already in
    /// flight (so callers don't count a skipped tick as a refresh).
    @discardableResult
    func triggerScan() -> Bool {
        lock.lock()
        if scanning { lock.unlock(); return false }
        scanning = true
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            // Always release the latch, even on an unexpected early return — a stuck
            // `scanning` would otherwise freeze every future scan.
            defer { self.lock.lock(); self.scanning = false; self.lock.unlock() }
            let result = HelperClient.shared.scan()   // persistent open-launched helper so SSIDs are visible
            let iface = self.scanner.interfaceName
            let conn = self.scanner.currentSSID
            self.lock.lock()
            if result.error == nil { self.nets = result.nets }
            self.scanError = result.error
            if let s = result.status { self.locationStatus = s }
            self.ifaceName = iface
            self.connSSID = conn
            self.lastScan = Date()
            self.scanCount += 1
            self.lock.unlock()
        }
        return true
    }

    func snapshot() -> (nets: [BSS], err: String?, last: Date?, scanning: Bool, count: Int,
                        iface: String, conn: String?, loc: String) {
        lock.lock(); defer { lock.unlock() }
        return (nets, scanError, lastScan, scanning, scanCount, ifaceName, connSSID, locationStatus)
    }

    func visibleNets(_ all: [BSS]) -> [BSS] {
        let filtered = bandFilter == nil ? all : all.filter { $0.band == bandFilter }
        return sortNets(filtered, by: sortKey, ascending: ascending)
    }
}

// MARK: - Terminal raw mode

var savedTermios = termios()
var rawActive: sig_atomic_t = 0

private func writeRaw(_ s: String) {
    var bytes = Array(s.utf8)
    _ = write(STDOUT_FILENO, &bytes, bytes.count)
}

func enterRaw() {
    tcgetattr(STDIN_FILENO, &savedTermios)
    rawActive = 1   // set first, so a signal arriving mid-setup still restores fully
    var raw = savedTermios
    raw.c_lflag &= ~(UInt(ECHO | ICANON | ISIG | IEXTEN))
    raw.c_iflag &= ~(UInt(IXON | ICRNL | BRKINT | INPCK | ISTRIP))
    raw.c_oflag &= ~(UInt(OPOST))
    // VMIN = 0, VTIME = 1 → read returns after 0.1s if no key (paces the loop).
    withUnsafeMutablePointer(to: &raw.c_cc) {
        $0.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { cc in
            cc[Int(VMIN)] = 0
            cc[Int(VTIME)] = 1
        }
    }
    tcsetattr(STDIN_FILENO, TCSANOW, &raw)
    writeRaw("\u{1B}[?1049h\u{1B}[?25l")   // alt screen + hide cursor
}

/// Async-signal-safe: uses only write() and tcsetattr() (both on the POSIX
/// async-signal-safe list) — never stdio — so it is safe to call from a signal
/// handler as well as the normal exit path. Idempotent via rawActive.
func leaveRaw() {
    guard rawActive != 0 else { return }
    rawActive = 0
    writeRaw("\u{1B}[?25h\u{1B}[?1049l")   // show cursor + main screen
    tcsetattr(STDIN_FILENO, TCSANOW, &savedTermios)
}

func readKey() -> Character? {
    var buf = [UInt8](repeating: 0, count: 1)
    let n = read(STDIN_FILENO, &buf, 1)
    guard n == 1 else { return nil }
    let b = buf[0]
    // Drain (and ignore) ANSI escape sequences (arrow keys etc.) so their trailing
    // bytes aren't mistaken for single-key commands.
    if b == 0x1B {
        var skip = [UInt8](repeating: 0, count: 8)
        _ = read(STDIN_FILENO, &skip, 8)   // VMIN=0/VTIME=1 → returns promptly
        return nil
    }
    // ASCII only — TUI commands are all single-byte; ignore multibyte UTF-8.
    return b < 0x80 ? Character(UnicodeScalar(b)) : nil
}

// MARK: - Interactive loop

func runInteractive(app: App) {
    // Install restore-on-signal BEFORE mutating terminal state (closes the
    // startup race). leaveRaw() is async-signal-safe; _exit() skips stdio+atexit.
    for sig in [SIGINT, SIGTERM] {
        signal(sig) { _ in
            // kill() is async-signal-safe; reap the persistent helper on Ctrl-C so
            // it doesn't linger (it would self-exit on heartbeat loss anyway).
            if helperPidGlobal > 0 { kill(helperPidGlobal, SIGTERM) }
            leaveRaw(); _exit(0)
        }
    }
    atexit { leaveRaw() }
    enterRaw()

    app.triggerScan()
    var lastAuto = Date()
    var lastBeat = Date.distantPast

    while !app.quit {
        // Heartbeat the persistent helper so it stays alive between scans (the
        // auto-refresh interval can be far longer than the helper's staleness window).
        if Date().timeIntervalSince(lastBeat) >= 3 {
            HelperClient.shared.beat()
            lastBeat = Date()
        }
        // Auto-refresh. Only reset the timer when a scan actually started, so a
        // tick skipped because a scan was still in flight retries next loop
        // instead of silently stretching the interval.
        if app.autoRefresh, Date().timeIntervalSince(lastAuto) >= app.interval {
            if app.triggerScan() { lastAuto = Date() }
        }
        draw(app)
        if let k = readKey() { handleKey(k, app: app) }
    }
    leaveRaw()
    HelperClient.shared.shutdown()
}

func handleKey(_ k: Character, app: App) {
    switch k {
    case "q", "\u{04}", "\u{03}": app.quit = true        // q / Ctrl-D / Ctrl-C (ISIG is off)
    case "r": app.triggerScan()
    case "a": app.autoRefresh.toggle()
    case "g", "\t": app.graphMode.toggle(); app.scroll = 0
    case "p": setSort(app, .power)
    case "s": setSort(app, .snr)
    case "c": setSort(app, .channel)
    case "n": setSort(app, .name)
    case "w": setSort(app, .width)
    case "e": setSort(app, .security)
    case "b": cycleBand(app)
    case "1": app.bandFilter = .ghz24; app.scroll = 0
    case "2": app.bandFilter = .ghz5; app.scroll = 0
    case "6": app.bandFilter = .ghz6; app.scroll = 0
    case "0": app.bandFilter = nil; app.scroll = 0
    case "j": app.scroll += 1
    case "k": app.scroll = max(0, app.scroll - 1)
    case "+", "=": app.interval = min(60, app.interval + 1)
    case "-", "_": app.interval = max(2, app.interval - 1)
    default: break
    }
}

func setSort(_ app: App, _ key: SortKey) {
    if app.sortKey == key { app.ascending.toggle() } else { app.sortKey = key; app.ascending = false }
    app.scroll = 0
}

func cycleBand(_ app: App) {
    switch app.bandFilter {
    case nil: app.bandFilter = .ghz24
    case .ghz24: app.bandFilter = .ghz5
    case .ghz5: app.bandFilter = .ghz6
    case .ghz6, .unknown: app.bandFilter = nil
    }
    app.scroll = 0
}

func draw(_ app: App) {
    let layout = termSize()
    let snap = app.snapshot()
    let visible = app.visibleNets(snap.nets)

    var lines: [String] = []

    // Header
    let scanningTag = snap.scanning ? Ansi.fg256(" ⟳ scanning…", 226) : ""
    let lastStr = snap.last.map { timeFormatter.string(from: $0) } ?? "—"
    let head1 = Ansi.bg256(Ansi.bold(Ansi.fg256("  wifiscan  ", 231)), 25)
        + " " + Ansi.fg256("iface ", 244) + Ansi.fg256(snap.iface, 252)
        + Ansi.fg256("  connected ", 244) + Ansi.fg256(snap.conn ?? "—", 252)
        + Ansi.fg256("  location ", 244)
        + Ansi.fg256(snap.loc, snap.loc == "authorized" ? 47 : 208)
        + scanningTag
    lines.append(clipAnsi(head1, layout.cols))

    let head2 = Ansi.fg256("networks ", 244) + Ansi.bold("\(snap.nets.count)")
        + Ansi.fg256("  shown ", 244) + "\(visible.count)"
        + Ansi.fg256("  view ", 244) + (app.graphMode ? "channel-map" : "list")
        + Ansi.fg256("  sort ", 244) + app.sortKey.label + (app.ascending ? "↑" : "↓")
        + Ansi.fg256("  filter ", 244) + bandFilterLabel(app.bandFilter)
        + Ansi.fg256("  auto ", 244) + (app.autoRefresh ? "on(\(Int(app.interval))s)" : "off")
        + Ansi.fg256("  last ", 244) + lastStr
    lines.append(clipAnsi(head2, layout.cols))
    lines.append(Ansi.dim(String(repeating: "─", count: min(layout.cols, 120))))

    if let err = snap.err {
        lines.append(clipAnsi(Ansi.fg256("scan error: \(err)", 196), layout.cols))
    }
    // SSID names are masked only when Location isn't authorized — distinguish that
    // from genuinely hidden (cloaked) APs using the helper's reported status.
    let hidden = snap.nets.filter { $0.hidden }.count
    if !snap.nets.isEmpty && hidden > 0 && snap.loc != "authorized" && snap.loc != "unknown" {
        lines.append(Ansi.fg256("⚠ SSIDs hidden — Location Services isn't active for wifiscan.", 208))
        lines.append(Ansi.dim("  Enable 'wifiscan' in System Settings → Privacy & Security → Location Services, then rerun."))
    }

    // Body
    let recLines = renderRecommendations(snap.nets)
    let footer = footerLines()
    let chrome = lines.count + recLines.count + footer.count + 2
    let bodyBudget = max(3, layout.rows - chrome)

    var body: [String]
    if app.graphMode {
        body = renderGraph(visible, cols: layout.cols)
    } else {
        body = renderTable(visible, cols: layout.cols)
    }
    // Scroll handling (keep header row when scrolling table).
    let headerRow = (!app.graphMode && !body.isEmpty) ? body.removeFirst() : nil
    let maxScroll = max(0, body.count - bodyBudget + (headerRow != nil ? 1 : 0))
    if app.scroll > maxScroll { app.scroll = maxScroll }
    var bodyView = Array(body.dropFirst(app.scroll).prefix(bodyBudget - (headerRow != nil ? 1 : 0)))
    if let h = headerRow { bodyView.insert(h, at: 0) }

    lines.append(contentsOf: bodyView)
    // Pad the body region so the bottom chrome sits flush at the bottom. `used` must
    // count ALL trailing lines — the separator (+1), the recommendations, and the
    // footer — otherwise the assembled frame overshoots layout.rows by one and the
    // prefix(layout.rows) below clips the last line (the footer).
    let used = lines.count + 1 + recLines.count + footer.count
    if used < layout.rows {
        lines.append(contentsOf: Array(repeating: "", count: layout.rows - used))
    }
    lines.append(Ansi.dim(String(repeating: "─", count: min(layout.cols, 120))))
    lines.append(contentsOf: recLines)
    lines.append(contentsOf: footer)

    // Paint. Clear each line to EOL rather than wiping the whole screen every frame
    // (that caused continuous flicker), and skip the write entirely when the frame
    // is byte-identical to the last one (the loop runs ~10x/s but data rarely changes).
    let painted = Array(lines.prefix(layout.rows))
    let sizeChanged = (layout.cols != app.lastCols || layout.rows != app.lastRows)
    var screen = sizeChanged ? "\u{1B}[2J\u{1B}[H" : "\u{1B}[H"
    screen += painted.map { $0 + "\u{1B}[K" }.joined(separator: "\r\n")
    screen += "\u{1B}[J"

    if screen == app.lastFrame && !sizeChanged { return }
    app.lastFrame = screen
    app.lastCols = layout.cols
    app.lastRows = layout.rows
    print(screen, terminator: "")
    fflush(stdout)
}

func footerLines() -> [String] {
    let keys = "[q]uit  [r]escan  [g]raph  [a]uto  [p]ower [s]nr [c]han [n]ame [w]idth s[e]c  [b]and 1/2/6/0  [j/k]scroll  [+/-]interval"
    return [Ansi.dim(keys)]
}

// MARK: - Diagnostics

func runDiag(app: App) {
    let s = app.scanner
    let res = HelperClient.shared.scan()   // scan via the open-launched helper, like the TUI
    defer { HelperClient.shared.shutdown() }
    let named = res.nets.filter { !$0.hidden }.count
    print("wifiscan diagnostics")
    print("  interface          : \(s.interfaceName)")
    print("  power on           : \(s.powerOn)")
    print("  connected ssid     : \(s.currentSSID ?? "—")")
    print("  helper location    : \(res.status ?? "unknown")")
    print("  scan error         : \(res.error ?? "none")")
    print("  networks found     : \(res.nets.count)")
    print("  SSIDs visible      : \(named)/\(res.nets.count)")
    print("  app bundle         : \(appBundlePath())")
    if res.nets.count > 0 && named == 0 {
        print("")
        print("  ⚠ SSIDs are masked — Location Services isn't authorized for wifiscan.")
        print("    System Settings → Privacy & Security → Location Services → enable 'wifiscan'.")
    }
}

// MARK: - One-shot (non-interactive) mode

func runOnce(app: App, json: Bool) {
    let result = HelperClient.shared.scan()
    HelperClient.shared.shutdown()   // one-shot mode: don't leave a daemon behind
    let nets = sortNets(result.nets, by: app.sortKey, ascending: app.ascending)
    if json {
        struct Out: Encodable {
            let ssid: String; let rssi: Int; let noise: Int?
            let snr: Int?; let channel: Int; let band: String; let widthMHz: Int
            let security: String; let hidden: Bool
        }
        let arr = nets.map { Out(ssid: $0.ssid, rssi: $0.rssi,
            noise: $0.noiseValid ? $0.noise : nil, snr: $0.snr, channel: $0.channel,
            band: $0.band.longLabel, widthMHz: $0.widthMHz, security: $0.security, hidden: $0.hidden) }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(arr), let s = String(data: d, encoding: .utf8) { print(s) }
        else { print("[]") }
        if let e = result.error { FileHandle.standardError.write(Data("scan error: \(e)\n".utf8)) }
        return
    }
    print(Ansi.bold("wifiscan — \(nets.count) networks  (iface \(app.scanner.interfaceName), connected \(app.scanner.currentSSID ?? "—"))"))
    if let e = result.error { print(Ansi.fg256("scan error: \(e)", 196)) }
    if !nets.isEmpty && result.status != "authorized" && nets.contains(where: { $0.hidden }) {
        print(Ansi.fg256("⚠ SSIDs hidden — enable 'wifiscan' in System Settings → Privacy & Security → Location Services.", 208))
    }
    print("")
    for line in renderTable(nets, cols: termSize().cols) { print(line) }
    print("")
    for line in renderGraph(nets, cols: termSize().cols) { print(line) }
    print("")
    for line in renderRecommendations(nets) { print(line) }
    print("")
    print(Ansi.dim("noise/SNR are only reported by macOS for the channel the radio is tuned to; ‹—› elsewhere is expected."))
}

// MARK: - Out-of-process scan helper
//
// macOS 26 redacts Wi-Fi SSIDs for any process that isn't launched as a real app
// session: a CLI spawned by a shell gets masked names even when Location Services
// is authorized. The fix (found empirically) is to perform each scan in a
// short-lived helper instance of ourselves launched via LaunchServices (`open`),
// which counts as an app session and sees real SSIDs, then hand the results back
// as JSON over a temp file.

struct ScanRecord: Codable {
    let ssid: String, rssi: Int, noise: Int, channel: Int
    let band: Int, widthMHz: Int, security: String, hidden: Bool
}
struct ScanFile: Codable {
    let error: String?
    let status: String?
    let nets: [ScanRecord]
}
private func record(_ b: BSS) -> ScanRecord {
    ScanRecord(ssid: b.ssid, rssi: b.rssi, noise: b.noise, channel: b.channel,
               band: b.band.rawValue, widthMHz: b.widthMHz, security: b.security, hidden: b.hidden)
}
private func bss(_ r: ScanRecord) -> BSS {
    BSS(ssid: r.ssid, rssi: r.rssi, noise: r.noise, channel: r.channel,
        band: Band.from(r.band), widthMHz: r.widthMHz, security: r.security, hidden: r.hidden)
}

/// Helper mode (reached only via `open`): briefly engage Location, scan, write JSON, exit.
final class ScanJSONHelper: NSObject, CLLocationManagerDelegate {
    private let mgr = CLLocationManager()
    private let path: String
    init(path: String) { self.path = path; super.init(); mgr.delegate = self }
    func go() {
        // Hard backstop: the helper must never hang the parent's `open -W` wait,
        // even if the scan/Location callback never returns.
        DispatchQueue.global().asyncAfter(deadline: .now() + 8) { exit(2) }
        mgr.requestWhenInUseAuthorization()
        mgr.startUpdatingLocation()
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [self] _ in
            let r = Scanner().scan()
            let status: String
            switch mgr.authorizationStatus {
            case .authorizedAlways, .authorized: status = "authorized"
            case .denied: status = "denied"
            case .restricted: status = "restricted"
            case .notDetermined: status = "not-determined"
            @unknown default: status = "unknown"
            }
            let out = ScanFile(error: r.error, status: status, nets: r.nets.map(record))
            do {
                let data = try JSONEncoder().encode(out)
                try data.write(to: URL(fileURLWithPath: path))
                exit(0)
            } catch {
                // Last-ditch: surface the failure so the front-end sees a cause
                // rather than a generic "no output".
                let fallback = ScanFile(error: "helper write failed: \(error.localizedDescription)",
                                        status: status, nets: [])
                if let d = try? JSONEncoder().encode(fallback) {
                    try? d.write(to: URL(fileURLWithPath: path))
                }
                exit(1)
            }
        }
        RunLoop.current.run()
    }
}

/// Resolve the real .app bundle path. Bundle.main is unreliable when we're invoked
/// through the ~/.bin/wifiscan symlink (it reports the symlink's directory), so we
/// resolve the actual executable and walk up to the enclosing ".app".
func appBundlePath() -> String {
    var size: UInt32 = 4096
    var buf = [CChar](repeating: 0, count: Int(size))
    var exe = Bundle.main.executablePath ?? (CommandLine.arguments.first ?? "")
    let rc = _NSGetExecutablePath(&buf, &size)
    if rc == 0 {
        exe = String(cString: buf)
    } else if rc == -1 {
        // Buffer too small; `size` now holds the required length — retry once.
        buf = [CChar](repeating: 0, count: Int(size))
        if _NSGetExecutablePath(&buf, &size) == 0 { exe = String(cString: buf) }
    }
    var u = URL(fileURLWithPath: exe).resolvingSymlinksInPath()   // follow the symlink into the bundle
    while u.pathExtension != "app" && u.path != "/" {
        u = u.deletingLastPathComponent()
    }
    return u.pathExtension == "app" ? u.path : Bundle.main.bundlePath
}

// MARK: Atomic file IPC helpers

func atomicWriteString(_ path: String, _ s: String) {
    try? s.write(toFile: path, atomically: true, encoding: .utf8)   // temp + rename
}
func readIntFile(_ path: String) -> Int? {
    guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    return Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
}
func processAlive(_ pid: pid_t) -> Bool { pid > 0 && kill(pid, 0) == 0 }

// MARK: One-shot helper (fallback + backward-compatible `--scan-json` path)

/// Run a single scan in a short-lived `open`-launched helper and read it back.
/// Used as a fallback when the persistent daemon can't be reached.
func oneShotScan(bundle: String) -> (nets: [BSS], error: String?, status: String?) {
    let tmp = NSTemporaryDirectory() + "wifiscan-\(getpid()).json"
    try? FileManager.default.removeItem(atPath: tmp)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    // -n new instance · -W wait for exit · -g don't foreground · -j launch hidden
    p.arguments = ["-n", "-W", "-g", "-j", bundle, "--args", "--scan-json", tmp]
    do { try p.run() } catch {
        return ([], "could not launch scan helper: \(error.localizedDescription)", nil)
    }
    let deadline = Date().addingTimeInterval(15)
    while p.isRunning && Date() < deadline { usleep(50_000) }
    if p.isRunning { p.terminate(); return ([], "scan helper timed out", nil) }
    guard let data = FileManager.default.contents(atPath: tmp) else {
        return ([], "scan helper produced no output", nil)
    }
    try? FileManager.default.removeItem(atPath: tmp)
    guard let f = try? JSONDecoder().decode(ScanFile.self, from: data) else {
        return ([], "could not parse scan helper output", nil)
    }
    return (f.nets.map(bss), f.error, f.status)
}

// MARK: Persistent scan daemon
//
// Rather than spawn a fresh `open`-launched app per scan (a new process + Location
// engagement + ~1s settle every refresh), launch ONE long-lived helper via `open`
// and drive it over a tiny file protocol in a per-front-end control dir:
//   pid             helper's pid (readiness signal)
//   req / resp      monotonic scan sequence — requested / completed
//   scan-<n>.json   the ScanFile for sequence n
//   beat            front-end heartbeat (epoch s); helper self-exits if it goes stale
// The helper stays a LaunchServices app session (so SSIDs reveal exactly as the
// per-scan helper did) and pays the Location settle only once, at startup.

var helperPidGlobal: pid_t = 0   // mirrored so the signal handler can SIGTERM it on exit

final class HelperClient {
    static let shared = HelperClient()
    private let dir = NSTemporaryDirectory() + "wifiscan-daemon-\(getpid())/"
    private let lock = NSLock()
    private var seq = 0
    private var helperPid: pid_t?

    /// Refresh the heartbeat so the daemon knows we're alive (call periodically).
    func beat() { atomicWriteString(dir + "beat", "\(Int(Date().timeIntervalSince1970))") }

    /// One scan: drive the persistent daemon, falling back to a one-shot helper if
    /// the daemon can't be reached (so scanning always works).
    func scan() -> (nets: [BSS], error: String?, status: String?) {
        lock.lock(); defer { lock.unlock() }
        let bundle = appBundlePath()
        // Without a real .app the `open` relaunch can't reveal SSIDs — fail clearly.
        guard bundle.hasSuffix(".app") else {
            return ([], "not running from a .app bundle — install with `make`; SSID scan needs the bundle's identity", nil)
        }
        if let res = daemonScan(bundle: bundle) { return res }
        return oneShotScan(bundle: bundle)
    }

    func shutdown() {
        lock.lock(); defer { lock.unlock() }
        if let p = helperPid, processAlive(p) { kill(p, SIGTERM) }
        helperPid = nil; helperPidGlobal = 0
        try? FileManager.default.removeItem(atPath: dir)
    }

    /// nil ⇒ infra failure (caller falls back to a one-shot scan).
    private func daemonScan(bundle: String) -> (nets: [BSS], error: String?, status: String?)? {
        guard ensureRunning(bundle: bundle) else { return nil }
        seq += 1
        let mySeq = seq
        atomicWriteString(dir + "req", "\(mySeq)")
        let deadline = Date().addingTimeInterval(mySeq == 1 ? 12 : 6)   // first scan settles Location
        while Date() < deadline {
            if let r = readIntFile(dir + "resp"), r >= mySeq {
                for _ in 0..<20 {     // the json is written before resp; allow fs settle
                    if let data = FileManager.default.contents(atPath: dir + "scan-\(mySeq).json"),
                       let f = try? JSONDecoder().decode(ScanFile.self, from: data) {
                        try? FileManager.default.removeItem(atPath: dir + "scan-\(mySeq).json")
                        return (f.nets.map(bss), f.error, f.status)
                    }
                    usleep(10_000)
                }
                return nil
            }
            usleep(25_000)
            beat()                 // keep the daemon alive while we wait
        }
        shutdown()                 // wedged helper → kill so the next call relaunches fresh
        return nil
    }

    private func ensureRunning(bundle: String) -> Bool {
        if let p = helperPid, processAlive(p) { return true }
        startHelper(bundle: bundle)
        return helperPid != nil
    }

    private func startHelper(bundle: String) {
        try? FileManager.default.removeItem(atPath: dir)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        seq = 0
        beat()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        // No -W: the helper persists; `open` returns once it has launched the app.
        p.arguments = ["-n", "-g", "-j", bundle, "--args", "--scan-daemon", dir]
        do { try p.run() } catch { return }
        p.waitUntilExit()          // waits for `open`, not the (detached) helper
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {   // wait for the helper to publish its pid
            if let pid = readIntFile(dir + "pid").map({ pid_t($0) }), processAlive(pid) {
                helperPid = pid; helperPidGlobal = pid; return
            }
            usleep(50_000)
            beat()
        }
    }
}

/// Persistent helper mode (reached only via `open … --scan-daemon <dir>`): engage
/// Location once, then serve scan requests over the control dir until the
/// front-end's heartbeat goes stale (it quit or crashed).
final class ScanDaemon: NSObject, CLLocationManagerDelegate {
    private let mgr = CLLocationManager()
    private let dir: String
    private let scanner = Scanner()
    private var lastDone = 0
    private var startTime = Date()
    private var lastActivity = Date()
    private var settled = false

    init(dir: String) { self.dir = dir; super.init(); mgr.delegate = self }

    /// Remove our control dir, then exit — used on self-exit paths (orphan/idle) so
    /// a SIGKILLed front-end doesn't leave the dir behind. (On a normal quit the
    /// front-end SIGTERMs us and removes the dir itself.)
    private func cleanExit() -> Never {
        try? FileManager.default.removeItem(atPath: dir)
        exit(0)
    }

    func run() {
        atomicWriteString(dir + "pid", "\(getpid())")   // publish readiness
        mgr.requestWhenInUseAuthorization()
        mgr.startUpdatingLocation()
        startTime = Date(); lastActivity = Date()
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [self] _ in tick() }
        RunLoop.current.run()
    }

    private func authStatus() -> String {
        switch mgr.authorizationStatus {
        case .authorizedAlways, .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not-determined"
        @unknown default: return "unknown"
        }
    }

    private func tick() {
        let now = Date()
        if !settled {     // one-time Location settle, same as the per-scan helper
            if now.timeIntervalSince(startTime) >= 1.0 { settled = true } else { return }
        }
        if let reqSeq = readIntFile(dir + "req"), reqSeq > lastDone {
            let r = scanner.scan()
            let out = ScanFile(error: r.error, status: authStatus(), nets: r.nets.map(record))
            if let data = try? JSONEncoder().encode(out) {
                try? data.write(to: URL(fileURLWithPath: dir + "scan-\(reqSeq).json"), options: .atomic)
            }
            atomicWriteString(dir + "resp", "\(reqSeq)")
            try? FileManager.default.removeItem(atPath: dir + "scan-\(reqSeq - 2).json")   // tidy
            lastDone = reqSeq
            lastActivity = now
        }
        // Self-exit once the front-end stops heart-beating …
        if now.timeIntervalSince(startTime) > 5 {
            if let b = readIntFile(dir + "beat") {
                if now.timeIntervalSince1970 - Double(b) > 15 { cleanExit() }
            } else {
                cleanExit()
            }
        }
        // … or after a long idle period, as an ultimate backstop.
        if now.timeIntervalSince(lastActivity) > 300 { cleanExit() }
    }
}

/// Best-effort sweep of temp files / daemon control dirs leaked by helpers that
/// crashed before cleanup. Live daemon dirs are kept fresh by the heartbeat, so
/// only genuinely stale (>5 min untouched) `wifiscan-*` items are removed.
func sweepStaleTempFiles() {
    let dir = NSTemporaryDirectory()
    guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
    let cutoff = Date().addingTimeInterval(-300)
    for name in items where name.hasPrefix("wifiscan-") {
        let path = dir + name
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let m = attrs[.modificationDate] as? Date, m < cutoff {
            try? FileManager.default.removeItem(atPath: path)
        }
    }
}

// MARK: - Relaunch in Terminal (for Finder/Spotlight/Dock launches)

/// Open Terminal and exec this binary there, so a double-click "opens the app".
/// `exec` replaces Terminal's shell with wifiscan, so quitting the TUI closes the
/// window. The in-bundle binary keeps the app's code identity, so Location works.
func relaunchInTerminal() {
    let exe = Bundle.main.executablePath ?? CommandLine.arguments.first ?? "wifiscan"
    let shellSafe = exe.replacingOccurrences(of: "'", with: "'\\''")   // shell single-quote escape
    let shellCmd = "clear; exec '\(shellSafe)'"
    // The command is interpolated into a double-quoted AppleScript string literal,
    // so escape AppleScript metacharacters too (backslash first, then quote) —
    // otherwise a '"' or '\' in the path breaks out of the literal.
    let asSafe = shellCmd
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    let script = """
    tell application "Terminal"
        activate
        do script "\(asSafe)"
    end tell
    """
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", script]
    try? p.run()
    p.waitUntilExit()
}

// MARK: - Entry

func printHelp() {
    print("""
    wifiscan — WiFi survey & channel planner (macOS, CoreWLAN)

    USAGE:
      wifiscan          interactive TUI (default)
      wifiscan --once   one scan: table + channel map + recommendations, then exit
      wifiscan --json   one scan as JSON on stdout
      wifiscan --diag   print scan/permission diagnostics
      wifiscan --help   show this help  (also -h)

    Colour is automatic: on in a terminal, off when piped/redirected (or set NO_COLOR).

    TUI KEYS:
      q / Ctrl-C / Ctrl-D quit · r rescan · g / Tab channel-map · a auto-refresh
      p/s/c/n/w/e sort (press again to reverse) · b cycle band
      1/2/6 filter band · 0 all bands · j/k scroll · +/- refresh interval
    """)
}

func main() {
    let args = CommandLine.arguments
    let app = App()

    if args.contains("--help") || args.contains("-h") { printHelp(); return }

    // Internal helper modes — reached only when relaunched via `open`, never typed.
    if let i = args.firstIndex(of: "--scan-json") {
        let out = i + 1 < args.count ? args[i+1] : NSTemporaryDirectory() + "wifiscan-scan.json"
        ScanJSONHelper(path: out).go()
        return
    }
    if let i = args.firstIndex(of: "--scan-daemon") {
        let d = i + 1 < args.count ? args[i+1] : NSTemporaryDirectory() + "wifiscan-daemon/"
        ScanDaemon(dir: d).run()
        return
    }

    // Colour is automatic: on for an interactive terminal, off when piped/redirected
    // (or when NO_COLOR is set). No flag needed.
    Ansi.enabled = ProcessInfo.processInfo.environment["NO_COLOR"] == nil && isatty(STDOUT_FILENO) != 0

    sweepStaleTempFiles()

    // If launched without a terminal to draw to (Finder/Spotlight/Dock), reopen in
    // Terminal. One-shot/pipe modes are exempt — they run headless.
    let interactive = !(args.contains("--once") || args.contains("--json") || args.contains("--diag"))
    if interactive && isatty(STDOUT_FILENO) == 0 {
        relaunchInTerminal()
        return
    }

    // Diagnostics and one-shot modes must run even with the radio off (that's
    // exactly when you reach for --diag), so the power check gates only the TUI.
    if args.contains("--diag") { runDiag(app: app); return }
    if args.contains("--json") { runOnce(app: app, json: true); return }
    if args.contains("--once") { runOnce(app: app, json: false); return }

    if !app.scanner.powerOn {
        FileHandle.standardError.write(Data("Wi-Fi is powered off (interface \(app.scanner.interfaceName)). Turn it on and retry.\n".utf8))
        exit(1)
    }
    runInteractive(app: app)
}

main()
