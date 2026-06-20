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

import CoreLocation
import CoreWLAN
import Darwin
import Foundation

// MARK: - Model

struct BSS {
    var ssid: String
    var rssi: Int          // dBm
    var noise: Int         // dBm (0 == not measured by macOS for this BSS)
    var channel: Int
    var band: Band
    var widthMHz: Int      // 20/40/80/160, 0 == unknown
    var security: String
    var hidden: Bool

    var snr: Int? { noise < 0 ? rssi - noise : nil }      // only when noise is real
    var noiseValid: Bool { noise < 0 }

    /// Linear power (relative mW) for energy-weighted congestion scoring.
    var linearPower: Double { pow(10.0, Double(rssi) / 10.0) }

    /// Inclusive [low, high] frequency span (MHz) actually occupied, accounting
    /// for channel bonding.
    var freqSpan: (lo: Double, hi: Double) {
        let w = widthMHz > 0 ? widthMHz : 20
        switch band {
        case .ghz24:
            // 2.4 GHz bonding is rare/discouraged; approximate around control freq.
            let fc = Band.centerFreq(.ghz24, channel)
            return (fc - Double(w) / 2.0, fc + Double(w) / 2.0)
        case .ghz5, .ghz6, .unknown:
            let chans = ChannelPlan.coveredChannels(band: band, control: channel, widthMHz: w)
            guard let first = chans.first, let last = chans.last else {
                let fc = Band.centerFreq(band, channel)
                return (fc - Double(w) / 2.0, fc + Double(w) / 2.0)
            }
            let lo = Band.centerFreq(band, first) - 10.0
            let hi = Band.centerFreq(band, last) + 10.0
            return (lo, hi)
        }
    }
}

enum Band: Int, CaseIterable {
    case unknown = 0, ghz24 = 1, ghz5 = 2, ghz6 = 3

    var label: String {
        switch self {
        case .ghz24: return "2.4"
        case .ghz5:  return "5"
        case .ghz6:  return "6"
        case .unknown: return "?"
        }
    }
    var longLabel: String {
        switch self {
        case .ghz24: return "2.4 GHz"
        case .ghz5:  return "5 GHz"
        case .ghz6:  return "6 GHz"
        case .unknown: return "?"
        }
    }

    static func from(_ raw: Int) -> Band { Band(rawValue: raw) ?? .unknown }

    /// Center frequency (MHz) of a 20 MHz control channel.
    static func centerFreq(_ band: Band, _ chan: Int) -> Double {
        switch band {
        case .ghz24:
            if chan == 14 { return 2484 }
            return 2412 + Double(chan - 1) * 5
        case .ghz5:
            return 5000 + Double(chan) * 5
        case .ghz6:
            if chan == 2 { return 5935 }
            return 5950 + Double(chan) * 5
        case .unknown:
            return 0
        }
    }
}

// MARK: - Channel plan (bonding → covered 20 MHz control channels)

enum ChannelPlan {
    // Standard 5 GHz bonded groups (control channels). Irregular due to UNII gaps.
    static let g5_40: [[Int]] = [
        [36,40],[44,48],[52,56],[60,64],
        [100,104],[108,112],[116,120],[124,128],
        [132,136],[140,144],[149,153],[157,161]
    ]
    static let g5_80: [[Int]] = [
        [36,40,44,48],[52,56,60,64],
        [100,104,108,112],[116,120,124,128],
        [132,136,140,144],[149,153,157,161]
    ]
    static let g5_160: [[Int]] = [
        [36,40,44,48,52,56,60,64],
        [100,104,108,112,116,120,124,128],
        [149,153,157,161,165,169,173,177]
    ]

    /// 20 MHz control channels covered by a (control, width) transmission.
    static func coveredChannels(band: Band, control: Int, widthMHz: Int) -> [Int] {
        if widthMHz <= 20 { return [control] }
        switch band {
        case .ghz5:
            let table: [[Int]]
            switch widthMHz {
            case 40:  table = g5_40
            case 80:  table = g5_80
            case 160: table = g5_160
            default:  table = []
            }
            if let g = table.first(where: { $0.contains(control) }) { return g }
            return [control]
        case .ghz6:
            // 6 GHz is a regular grid: 20 MHz control channels are 1,5,9,...,233.
            guard control >= 1 else { return [control] }
            let slot = (control - 1) / 4          // 0-based 20 MHz slot
            let groupSize = widthMHz / 20          // # of 20 MHz slots bonded
            let start = (slot / groupSize) * groupSize
            return (0..<groupSize).map { 1 + (start + $0) * 4 }
        case .ghz24:
            return [control]
        case .unknown:
            return [control]
        }
    }

    // Candidate control channels worth recommending per band.
    static let cand24 = [1, 6, 11]
    static let cand5NonDFS = [36, 40, 44, 48, 149, 153, 157, 161]
    static let cand5DFS = [52,56,60,64,100,104,108,112,116,120,124,128,132,136,140,144]
    static let cand6PSC = [5, 21, 37, 53, 69, 85, 101, 117, 133, 149, 165, 181, 197, 213, 229]

    /// True for 5 GHz channels that require DFS (radar avoidance).
    static func isDFS(_ chan: Int) -> Bool { cand5DFS.contains(chan) }
}

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
                    widthMHz: Scanner.widthToMHz(ch?.channelWidth.rawValue ?? 0),
                    security: Scanner.securityLabel(n),
                    hidden: (n.ssid?.isEmpty != false)
                )
            }
            return (nets, nil)
        } catch {
            return ([], error.localizedDescription)
        }
    }

    static func widthToMHz(_ raw: Int) -> Int {
        switch raw {
        case 1: return 20
        case 2: return 40
        case 3: return 80
        case 4: return 160
        default: return 0
        }
    }
}

// MARK: - Congestion analysis

struct ChannelLoad {
    let channel: Int
    var apCount: Int = 0
    var weighted: Double = 0      // sum of linear power overlapping this channel
    var strongest: Int = -127     // strongest RSSI overlapping this channel
}

enum Analysis {
    /// Score every candidate control channel by the energy that overlaps it.
    static func loads(_ nets: [BSS], band: Band, candidates: [Int]) -> [ChannelLoad] {
        let inBand = nets.filter { $0.band == band }
        return candidates.map { cand in
            let span = (Band.centerFreq(band, cand) - 10.0, Band.centerFreq(band, cand) + 10.0)
            var load = ChannelLoad(channel: cand)
            for ap in inBand {
                let s = ap.freqSpan
                if s.lo < span.1 && s.hi > span.0 {     // intervals overlap
                    load.apCount += 1
                    load.weighted += ap.linearPower
                    load.strongest = max(load.strongest, ap.rssi)
                }
            }
            return load
        }
    }

    /// Cleanest candidates first (least overlapping energy, then fewest APs).
    static func recommend(_ nets: [BSS], band: Band, candidates: [Int]) -> [ChannelLoad] {
        loads(nets, band: band, candidates: candidates)
            .sorted { a, b in
                if a.weighted != b.weighted { return a.weighted < b.weighted }
                return a.apCount < b.apCount
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

    // Signal → colour (256-palette).
    static func signalColor(_ rssi: Int) -> Int {
        switch rssi {
        case let r where r >= -50: return 46    // bright green
        case let r where r >= -60: return 82    // green
        case let r where r >= -67: return 226   // yellow
        case let r where r >= -75: return 208   // orange
        default: return 196                      // red
        }
    }

    static func signalBar(_ rssi: Int, width: Int = 10) -> String {
        // Map -90..-30 dBm → 0..width blocks.
        let frac = max(0.0, min(1.0, Double(rssi + 90) / 60.0))
        let filled = Int((frac * Double(width)).rounded())
        let bar = String(repeating: "█", count: filled) + String(repeating: "·", count: width - filled)
        return fg256(bar, signalColor(rssi))
    }
}

func padTo(_ s: String, _ n: Int) -> String {
    let len = s.count
    if len >= n { return String(s.prefix(n)) }
    return s + String(repeating: " ", count: n - len)
}
func padLeft(_ s: String, _ n: Int) -> String {
    let len = s.count
    if len >= n { return String(s.prefix(n)) }
    return String(repeating: " ", count: n - len) + s
}

// MARK: - Sorting

enum SortKey: String {
    case power, snr, channel, name, band, width, security
    var label: String {
        switch self {
        case .power: return "Power"
        case .snr: return "SNR"
        case .channel: return "Channel"
        case .name: return "Name"
        case .band: return "Band"
        case .width: return "Width"
        case .security: return "Security"
        }
    }
}

func sortNets(_ nets: [BSS], by key: SortKey, ascending: Bool) -> [BSS] {
    let sorted = nets.sorted { a, b in
        switch key {
        case .power:    return a.rssi != b.rssi ? a.rssi > b.rssi : a.ssid < b.ssid
        case .snr:      return (a.snr ?? -999) != (b.snr ?? -999) ? (a.snr ?? -999) > (b.snr ?? -999) : a.rssi > b.rssi
        case .channel:  return a.channel != b.channel ? a.channel < b.channel : a.rssi > b.rssi
        case .name:     return a.ssid.lowercased() != b.ssid.lowercased() ? a.ssid.lowercased() < b.ssid.lowercased() : a.rssi > b.rssi
        case .band:     return a.band.rawValue != b.band.rawValue ? a.band.rawValue < b.band.rawValue : a.rssi > b.rssi
        case .width:    return a.widthMHz != b.widthMHz ? a.widthMHz > b.widthMHz : a.rssi > b.rssi
        case .security: return a.security != b.security ? a.security < b.security : a.rssi > b.rssi
        }
    }
    return ascending ? sorted.reversed() : sorted
}

// MARK: - Rendering

let timeFormatter: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
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
        let bar = Ansi.signalBar(n.rssi, width: wBar - 1) + " "
        let snr = padLeft(snrStr, wSnr)
        let sec = padTo(n.security, wSec)
        let line = [ssid, chan, band, padLeft(widthStr, wWidth), dbm, padTo(bar, wBar + 9), snr, sec]
            .joined(separator: " ")
        out.append(line)
    }
    return out
}

func renderGraph(_ nets: [BSS], cols: Int) -> [String] {
    var out: [String] = []
    let bands: [(Band, [Int])] = [
        (.ghz24, ChannelPlan.cand24 + [2,3,4,5,7,8,9,10]),
        (.ghz5, ChannelPlan.cand5NonDFS + ChannelPlan.cand5DFS),
        (.ghz6, Array(stride(from: 1, through: 93, by: 4))),
    ]
    for (band, _) in bands {
        let inBand = nets.filter { $0.band == band }
        if inBand.isEmpty { continue }
        out.append("")
        out.append(Ansi.bold(Ansi.fg256("▎ \(band.longLabel)  (\(inBand.count) networks)", 39)))

        // Occupancy per active channel, weighted by overlapping energy.
        let activeChans = Set(inBand.map { $0.channel }).sorted()
        let loads = Analysis.loads(nets, band: band, candidates: activeChans)
        let maxW = max(loads.map { $0.weighted }.max() ?? 1, 1e-9)
        for load in loads.sorted(by: { $0.channel < $1.channel }) {
            let barLen = Int((load.weighted / maxW) * Double(min(cols - 28, 40)))
            let bar = String(repeating: "█", count: max(load.weighted > 0 ? 1 : 0, barLen))
            let dfs = (band == .ghz5 && ChannelPlan.isDFS(load.channel)) ? Ansi.fg256(" DFS", 244) : ""
            let label = padLeft("ch \(load.channel)", 7)
            let cnt = padLeft("\(load.apCount)ap", 5)
            let strongest = padLeft("\(load.strongest)dBm", 8)
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
        return recs.prefix(3).map { r -> String in
            let dfs = (band == .ghz5 && ChannelPlan.isDFS(r.channel)) ? "*" : ""
            let tag = "ch \(r.channel)\(dfs) (\(r.apCount)ap)"
            return r.channel == best.channel ? Ansi.bold(Ansi.fg256(tag, 46)) : Ansi.fg256(tag, 250)
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
    var nets: [BSS] = []
    var scanError: String?
    var lastScan: Date?
    var scanning = false
    var scanCount = 0

    // UI state
    var sortKey: SortKey = .power
    var ascending = false
    var bandFilter: Band? = nil
    var graphMode = false
    var autoRefresh = true
    var interval: TimeInterval = 6
    var scroll = 0
    var quit = false
    var locationStatus = "unknown"

    func triggerScan() {
        lock.lock()
        if scanning { lock.unlock(); return }
        scanning = true
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let result = scanViaHelper()   // scan in an open-launched helper so SSIDs are visible
            self.lock.lock()
            if result.error == nil { self.nets = result.nets }
            self.scanError = result.error
            if let s = result.status { self.locationStatus = s }
            self.lastScan = Date()
            self.scanning = false
            self.scanCount += 1
            self.lock.unlock()
        }
    }

    func snapshot() -> (nets: [BSS], err: String?, last: Date?, scanning: Bool, count: Int) {
        lock.lock(); defer { lock.unlock() }
        return (nets, scanError, lastScan, scanning, scanCount)
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
    // ASCII only — TUI commands are all single-byte; ignore multibyte UTF-8
    // (each continuation byte simply falls through without spurious matches).
    if n == 1, buf[0] < 0x80 { return Character(UnicodeScalar(buf[0])) }
    return nil
}

// MARK: - Interactive loop

func runInteractive(app: App) {
    // Install restore-on-signal BEFORE mutating terminal state (closes the
    // startup race). leaveRaw() is async-signal-safe; _exit() skips stdio+atexit.
    for sig in [SIGINT, SIGTERM] {
        signal(sig) { _ in leaveRaw(); _exit(0) }
    }
    atexit { leaveRaw() }
    enterRaw()

    app.triggerScan()
    var lastAuto = Date()

    while !app.quit {
        // Auto-refresh.
        if app.autoRefresh, Date().timeIntervalSince(lastAuto) >= app.interval {
            app.triggerScan()
            lastAuto = Date()
        }
        draw(app)
        if let k = readKey() { handleKey(k, app: app) }
    }
    leaveRaw()
}

func handleKey(_ k: Character, app: App) {
    switch k {
    case "q", "\u{04}", "\u{03}": app.quit = true        // q / Ctrl-D / Ctrl-C (ISIG is off)
    case "r": app.triggerScan()
    case "a": app.autoRefresh.toggle()
    case "g", "\t": app.graphMode.toggle()
    case "p": setSort(app, .power)
    case "s": setSort(app, .snr)
    case "c": setSort(app, .channel)
    case "n": setSort(app, .name)
    case "w": setSort(app, .width)
    case "e": setSort(app, .security)
    case "b": cycleBand(app)
    case "1": app.bandFilter = .ghz24
    case "2": app.bandFilter = .ghz5
    case "6": app.bandFilter = .ghz6
    case "0": app.bandFilter = nil
    case "j": app.scroll += 1
    case "k": app.scroll = max(0, app.scroll - 1)
    case "+", "=": app.interval = min(60, app.interval + 1)
    case "-", "_": app.interval = max(2, app.interval - 1)
    default: break
    }
}

func setSort(_ app: App, _ key: SortKey) {
    if app.sortKey == key { app.ascending.toggle() } else { app.sortKey = key; app.ascending = false }
}

func cycleBand(_ app: App) {
    switch app.bandFilter {
    case nil: app.bandFilter = .ghz24
    case .ghz24: app.bandFilter = .ghz5
    case .ghz5: app.bandFilter = .ghz6
    case .ghz6: app.bandFilter = nil
    default: app.bandFilter = nil
    }
}

func draw(_ app: App) {
    let layout = termSize()
    let snap = app.snapshot()
    let visible = app.visibleNets(snap.nets)

    var lines: [String] = []

    // Header
    let scanningTag = snap.scanning ? Ansi.fg256(" ⟳ scanning…", 226) : ""
    let lastStr: String
    if let d = snap.last {
        lastStr = timeFormatter.string(from: d)
    } else { lastStr = "—" }
    let head1 = Ansi.bg256(Ansi.bold(Ansi.fg256("  wifiscan  ", 231)), 25)
        + " " + Ansi.fg256("iface ", 244) + Ansi.fg256(app.scanner.interfaceName, 252)
        + Ansi.fg256("  connected ", 244) + Ansi.fg256(app.scanner.currentSSID ?? "—", 252)
        + Ansi.fg256("  location ", 244)
        + Ansi.fg256(app.locationStatus, app.locationStatus == "authorized" ? 47 : 208)
        + scanningTag
    lines.append(head1)

    let head2 = Ansi.fg256("networks ", 244) + Ansi.bold("\(snap.nets.count)")
        + Ansi.fg256("  shown ", 244) + "\(visible.count)"
        + Ansi.fg256("  view ", 244) + (app.graphMode ? "channel-map" : "list")
        + Ansi.fg256("  sort ", 244) + app.sortKey.label + (app.ascending ? "↑" : "↓")
        + Ansi.fg256("  filter ", 244) + bandFilterLabel(app.bandFilter)
        + Ansi.fg256("  auto ", 244) + (app.autoRefresh ? "on(\(Int(app.interval))s)" : "off")
        + Ansi.fg256("  last ", 244) + lastStr
    lines.append(head2)
    lines.append(Ansi.dim(String(repeating: "─", count: min(layout.cols, 120))))

    if let err = snap.err {
        lines.append(Ansi.fg256("scan error: \(err)", 196))
    }
    let hidden = snap.nets.filter { $0.hidden }.count
    if !snap.nets.isEmpty && hidden == snap.nets.count {
        lines.append(Ansi.fg256("⚠ all SSIDs hidden — Location Services isn't active for wifiscan.", 208))
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
    // Pad to push recommendations + footer toward the bottom.
    let used = lines.count + recLines.count + footer.count
    if used < layout.rows {
        lines.append(contentsOf: Array(repeating: "", count: layout.rows - used))
    }
    lines.append(Ansi.dim(String(repeating: "─", count: min(layout.cols, 120))))
    lines.append(contentsOf: recLines)
    lines.append(contentsOf: footer)

    // Paint
    var screen = "\u{1B}[H\u{1B}[2J"   // home + clear
    screen += lines.prefix(layout.rows).joined(separator: "\r\n")
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
    let res = scanViaHelper()   // scan via the open-launched helper, like the TUI
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
    let result = scanViaHelper()
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
        if let e = result.error { FileHandle.standardError.write(Data("scan error: \(e)\n".utf8)) }
        return
    }
    print(Ansi.bold("wifiscan — \(nets.count) networks  (iface \(app.scanner.interfaceName), connected \(app.scanner.currentSSID ?? "—"))"))
    if let e = result.error { print(Ansi.fg256("scan error: \(e)", 196)) }
    let hidden = nets.filter { $0.hidden }.count
    if !nets.isEmpty && hidden == nets.count {
        print(Ansi.fg256("⚠ all SSIDs hidden — enable 'wifiscan' in System Settings → Privacy & Security → Location Services.", 208))
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
            if let data = try? JSONEncoder().encode(out) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
            exit(0)
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
    if _NSGetExecutablePath(&buf, &size) == 0 { exe = String(cString: buf) }
    var u = URL(fileURLWithPath: exe).resolvingSymlinksInPath()   // follow the symlink into the bundle
    while u.pathExtension != "app" && u.path != "/" {
        u = u.deletingLastPathComponent()
    }
    return u.pathExtension == "app" ? u.path : Bundle.main.bundlePath
}

/// Front-end side: run one scan in an `open`-launched helper and read it back.
func scanViaHelper() -> (nets: [BSS], error: String?, status: String?) {
    let tmp = NSTemporaryDirectory() + "wifiscan-\(getpid()).json"
    try? FileManager.default.removeItem(atPath: tmp)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    // -n new instance · -W wait for exit · -g don't foreground · -j launch hidden
    p.arguments = ["-n", "-W", "-g", "-j", appBundlePath(), "--args", "--scan-json", tmp]
    do { try p.run() } catch {
        return ([], "could not launch scan helper: \(error.localizedDescription)", nil)
    }
    p.waitUntilExit()
    guard let data = FileManager.default.contents(atPath: tmp) else {
        return ([], "scan helper produced no output", nil)
    }
    try? FileManager.default.removeItem(atPath: tmp)
    guard let f = try? JSONDecoder().decode(ScanFile.self, from: data) else {
        return ([], "could not parse scan helper output", nil)
    }
    return (f.nets.map(bss), f.error, f.status)
}

// MARK: - Relaunch in Terminal (for Finder/Spotlight/Dock launches)

/// Open Terminal and exec this binary there, so a double-click "opens the app".
/// `exec` replaces Terminal's shell with wifiscan, so quitting the TUI closes the
/// window. The in-bundle binary keeps the app's code identity, so Location works.
func relaunchInTerminal() {
    let exe = Bundle.main.executablePath ?? CommandLine.arguments.first ?? "wifiscan"
    let safe = exe.replacingOccurrences(of: "'", with: "'\\''")   // shell single-quote escape
    let script = """
    tell application "Terminal"
        activate
        do script "clear; exec '\(safe)'"
    end tell
    """
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", script]
    try? p.run()
    p.waitUntilExit()
}

// MARK: - Entry

func main() {
    let args = CommandLine.arguments
    let app = App()
    if args.contains("--no-color") { Ansi.enabled = false }
    if let i = args.firstIndex(of: "--interval"), i + 1 < args.count, let v = TimeInterval(args[i+1]) {
        app.interval = max(2, v)
    }
    if let i = args.firstIndex(of: "--sort"), i + 1 < args.count, let k = SortKey(rawValue: args[i+1]) {
        app.sortKey = k
    }
    if args.contains("--help") || args.contains("-h") {
        print("""
        wifiscan — WiFi survey & channel planner (macOS, CoreWLAN)

        USAGE:
          wifiscan                 interactive TUI (default)
          wifiscan --once          one scan, print table + channel map + recommendations
          wifiscan --json          one scan, emit JSON
          wifiscan --diag          print scan/permission diagnostics
          wifiscan --no-color      disable ANSI colour
          wifiscan --interval N     auto-refresh seconds (default 6)
          wifiscan --sort KEY       power|snr|channel|name|band|width|security

        TUI KEYS:
          q quit · r rescan · g channel-map · a auto-refresh toggle
          p/s/c/n/w/e sort · b cycle band · 1/2/6 band filter · 0 all
          j/k scroll · +/- refresh interval
        """)
        return
    }
    // Helper mode: reached only when relaunched via `open` to perform one scan.
    if let i = args.firstIndex(of: "--scan-json") {
        let out = i + 1 < args.count ? args[i+1] : NSTemporaryDirectory() + "wifiscan-scan.json"
        ScanJSONHelper(path: out).go()
        return
    }
    // If launched without a terminal (double-clicked in Finder / Spotlight / Dock),
    // reopen inside Terminal so the TUI has somewhere to draw. One-shot/pipe modes
    // are exempt — they're meant to run headless.
    let interactive = !(args.contains("--once") || args.contains("--json")
        || args.contains("--diag") || args.contains("--no-relaunch"))
    if interactive && isatty(STDIN_FILENO) == 0 {
        relaunchInTerminal()
        return
    }
    if !app.scanner.powerOn {
        FileHandle.standardError.write(Data("Wi-Fi is powered off (interface \(app.scanner.interfaceName)). Turn it on and retry.\n".utf8))
        exit(1)
    }
    if args.contains("--diag") { runDiag(app: app); return }
    if args.contains("--json") { runOnce(app: app, json: true); return }
    if args.contains("--once") { runOnce(app: app, json: false); return }
    runInteractive(app: app)
}

main()
