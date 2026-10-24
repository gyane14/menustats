import AppKit
import ServiceManagement
import SystemConfiguration
import os

// View with (full path: zsh has its own `log` builtin): /usr/bin/log stream --level debug --predicate 'subsystem == "io.github.gyane14.menustats"'
let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "io.github.gyane14.menustats", category: "app")
var failing = Set<String>()
var echoToStderr = false // --once: also print problems to the terminal

/// Logs a failure when it starts and again when it clears, so a lasting problem doesn't flood the log every 2 s.
func report(_ what: String, failed: Bool, _ detail: @autoclosure () -> String = "") {
    if failed {
        guard failing.insert(what).inserted else { return }
        let d = detail()
        log.error("\(what, privacy: .public) failed: \(d, privacy: .public)")
        if echoToStderr { FileHandle.standardError.write("menustats: \(what) failed: \(d)\n".data(using: .utf8)!) }
    } else if failing.remove(what) != nil {
        log.notice("\(what, privacy: .public) recovered")
    }
}

func errnoText() -> String { "\(String(cString: strerror(errno))) (errno \(errno))" }

/// Scales bytes to the largest unit below `base`: (value, unit index 0=B ... 4=T).
func scaled(_ bytes: Double, base: Double) -> (Double, Int) {
    var v = bytes, i = 0
    while v >= base && i < 4 { v /= base; i += 1 }
    return (v, i)
}

// Disk/network in decimal units (like Finder), memory in binary units (like Activity Monitor).
// Compact ("1.2M") for the menu bar, spaced ("1.2 MB") for the dropdown.
func fmt(_ bytes: Double, base: Double = 1000, long: Bool = false) -> String {
    let units = ["B", "K", "M", "G", "T"]
    let (v, i) = scaled(bytes, base: base)
    let unit = long ? (i == 0 ? " B" : " \(units[i])B") : units[i]
    return i == 0 ? "\(Int(v))\(unit)" : String(format: v < 10 ? "%.1f%@" : "%.0f%@", v, unit)
}

/// Spoken form for VoiceOver: "2.0 kilobytes".
func say(_ bytes: Double, base: Double = 1000) -> String {
    let names = ["bytes", "kilobytes", "megabytes", "gigabytes", "terabytes"]
    let (v, i) = scaled(bytes, base: base)
    return i == 0 ? "\(Int(v)) bytes" : String(format: v < 10 ? "%.1f %@" : "%.0f %@", v, names[i])
}

func percent(_ part: Double, _ whole: Double) -> String { whole > 0 ? "\(Int((part / whole * 100).rounded()))%" : "–" }

/// Byte counters per en* interface (Wi-Fi, Ethernet), via 64-bit counters.
/// getifaddrs' if_data is 32-bit and wraps at 4 GiB, so NET_RT_IFLIST2 is used instead.
/// utun/bridge/awdl/lo are skipped so VPN and Thunderbolt-bridge traffic is not counted twice.
func networkBytes() -> [String: (down: UInt64, up: UInt64)] {
    var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
    var len = 0
    guard sysctl(&mib, 6, nil, &len, nil, 0) == 0 else { report("network counters", failed: true, errnoText()); return [:] }
    var buf = [UInt8](repeating: 0, count: len)
    guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { report("network counters", failed: true, errnoText()); return [:] }
    var out: [String: (down: UInt64, up: UInt64)] = [:]
    buf.withUnsafeBytes { raw in
        var off = 0
        while off + MemoryLayout<if_msghdr>.size <= len {
            let hdr = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr.self)
            if hdr.ifm_msglen == 0 { break }
            // bounds check: never read past the buffer, even if the kernel hands back something unexpected
            if hdr.ifm_type == RTM_IFINFO2,
               off + MemoryLayout<if_msghdr2>.size + MemoryLayout<sockaddr_dl>.size <= len {
                let m = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr2.self)
                // sockaddr_dl follows the header and carries the interface name
                let sdl = raw.loadUnaligned(fromByteOffset: off + MemoryLayout<if_msghdr2>.size, as: sockaddr_dl.self)
                let name = withUnsafeBytes(of: sdl.sdl_data) { String(decoding: $0.prefix(Int(sdl.sdl_nlen)), as: UTF8.self) }
                if name.hasPrefix("en") { out[name] = (m.ifm_data.ifi_ibytes, m.ifm_data.ifi_obytes) }
            }
            off += Int(hdr.ifm_msglen)
        }
    }
    report("network counters", failed: out.isEmpty, "no Wi-Fi/Ethernet (en*) interfaces found")
    return out
}

/// "en0" -> "Wi-Fi", "en5" -> "USB 10/100/1000 LAN", etc.
func interfaceNames() -> [String: String] {
    var out: [String: String] = [:]
    for i in SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? [] {
        if let bsd = SCNetworkInterfaceGetBSDName(i) as String?, let name = SCNetworkInterfaceGetLocalizedDisplayName(i) as String? {
            out[bsd] = name
        }
    }
    report("interface names", failed: out.isEmpty, "SCNetworkInterfaceCopyAll returned none; showing BSD names")
    return out
}

/// The categories Activity Monitor shows; "used" = app memory + wired + compressed.
struct Memory {
    var app = 0.0, wired = 0.0, compressed = 0.0, cached = 0.0, swap = 0.0
    var total = Double(ProcessInfo.processInfo.physicalMemory)
    var pressure: Int32 = 0
    var used: Double { app + wired + compressed }
}

func memory() -> Memory {
    var m = Memory()
    var s = vm_statistics64()
    var n = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    let r = withUnsafeMutablePointer(to: &s) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &n) }
    }
    report("memory statistics", failed: r != KERN_SUCCESS, "host_statistics64 returned \(r)")
    guard r == KERN_SUCCESS else { return m }
    let page = Double(vm_kernel_page_size)
    m.app = max(0, Double(s.internal_page_count) - Double(s.purgeable_count)) * page
    m.wired = Double(s.wire_count) * page
    m.compressed = Double(s.compressor_page_count) * page
    m.cached = (Double(s.external_page_count) + Double(s.purgeable_count)) * page
    var swap = xsw_usage(), size = MemoryLayout<xsw_usage>.size
    let swapOK = sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0
    report("swap usage", failed: !swapOK, errnoText())
    if swapOK { m.swap = Double(swap.xsu_used) }
    size = MemoryLayout<Int32>.size
    report("memory pressure", failed: sysctlbyname("kern.memorystatus_vm_pressure_level", &m.pressure, &size, nil, 0) != 0, errnoText())
    return m
}

/// Startup disk. "available" matches Finder (purgeable space counts as free); "free" excludes purgeable.
struct Disk {
    var name: String, total: Double, available: Double, free: Double
    var used: Double { total - min(total, available) }
    var purgeable: Double { max(0, available - free) }
}

func disk() -> Disk? {
    let a: [FileAttributeKey: Any]
    do { a = try FileManager.default.attributesOfFileSystem(forPath: "/") } catch {
        report("disk size", failed: true, "\(error)")
        return nil
    }
    guard let total = (a[.systemSize] as? NSNumber)?.doubleValue else {
        report("disk size", failed: true, "no systemSize attribute for /")
        return nil
    }
    report("disk size", failed: false)
    let free = (a[.systemFreeSize] as? NSNumber)?.doubleValue ?? 0
    var important: Int64?
    do {
        important = try URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        report("disk available", failed: important == nil, "no important-usage capacity; showing free space instead")
    } catch {
        report("disk available", failed: true, "\(error); showing free space instead")
    }
    return Disk(name: FileManager.default.displayName(atPath: "/"), total: total,
                available: important.map(Double.init) ?? free, free: free)
}

struct Sampler {
    var last: (t: TimeInterval, bytes: [String: (down: UInt64, up: UInt64)])?
    let names = interfaceNames()

    /// Short text for the menu bar (it must fit beside the notch) and labelled rows for the dropdown.
    /// A row with an empty value is a section heading.
    mutating func sample(disk d: Disk?) -> (bar: [(top: String, bottom: String)], rows: [(String, String)], spoken: String) {
        let now = ProcessInfo.processInfo.systemUptime, bytes = networkBytes()
        var rate: [String: (down: Double, up: Double)] = [:]
        if let l = last, now > l.t {
            for (name, b) in bytes {
                // a counter going backwards (or a new interface) means a reset: show 0 for this sample
                guard let p = l.bytes[name] else { rate[name] = (0, 0); continue }
                rate[name] = (b.down >= p.down ? Double(b.down - p.down) / (now - l.t) : 0,
                              b.up >= p.up ? Double(b.up - p.up) / (now - l.t) : 0)
            }
        }
        last = (now, bytes)
        let down = rate.isEmpty ? nil : rate.values.reduce(0) { $0 + $1.down }
        let up = rate.isEmpty ? nil : rate.values.reduce(0) { $0 + $1.up }
        let speed = { (v: Double?, long: Bool) in v.map { fmt($0, long: long) + (long ? "/s" : "") } ?? "–" }

        var rows: [(String, String)] = [("NETWORK", ""),
                                        ("Download", speed(down, true)),
                                        ("Upload", speed(up, true))]
        // only interfaces that have carried traffic, busiest first
        for (name, b) in bytes.filter({ $0.value.down + $0.value.up > 0 }).sorted(by: { $0.value.down > $1.value.down }) {
            let r = rate[name]
            rows.append(("\(names[name] ?? name) (\(name))", "↓\(speed(r?.down, true))  ↑\(speed(r?.up, true))"))
            rows.append(("   since boot", "↓\(fmt(Double(b.down), long: true))  ↑\(fmt(Double(b.up), long: true))"))
        }

        let m = memory()
        let pressure = [1: "Normal", 2: "Warning", 4: "Critical"][Int(m.pressure)] ?? "Unknown"
        let mem = { (v: Double) in fmt(v, base: 1024, long: true) }
        rows += [("MEMORY", ""),
                 ("Used", "\(mem(m.used)) of \(mem(m.total)) (\(percent(m.used, m.total)))"),
                 ("App memory", mem(m.app)),
                 ("Wired", mem(m.wired)),
                 ("Compressed", mem(m.compressed)),
                 ("Cached files", mem(m.cached)),
                 ("Swap used", mem(m.swap)),
                 ("Pressure", pressure)]

        if let d {
            rows += [("DISK (\(d.name))", ""),
                     ("Used", "\(fmt(d.used, long: true)) of \(fmt(d.total, long: true)) (\(percent(d.used, d.total)))"),
                     ("Available", fmt(d.available, long: true)),
                     ("Free now", fmt(d.free, long: true)),
                     ("Purgeable", fmt(d.purgeable, long: true))]
        } else {
            rows += [("DISK", "unavailable")]
        }

        let bar = [(top: "↑: \(speed(up, false))", bottom: "↓: \(speed(down, false))"),
                   (top: "M: \(fmt(m.used, base: 1024))", bottom: "D: \(d.map { fmt($0.used) } ?? "?")")]
        // what VoiceOver reads for the menu bar item, since the item itself is an image
        let perSecond = { (v: Double?) in v.map { "\(say($0)) per second" } ?? "not measured yet" }
        let spoken = "Upload \(perSecond(up)), download \(perSecond(down)), "
            + "memory used \(say(m.used, base: 1024)) of \(say(m.total, base: 1024)), "
            + (d.map { "disk used \(say($0.used)) of \(say($0.total))" } ?? "disk unavailable")
        return (bar, rows, spoken)
    }
}

/// Two-line menu bar title: each column has its top text above its bottom text, split by a thin rule.
/// Template image, so macOS tints it for light/dark menu bars like regular text.
func barImage(_ cols: [(top: String, bottom: String)]) -> NSImage {
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium),
                                                .foregroundColor: NSColor.black]
    let width = { (s: String) in ceil((s as NSString).size(withAttributes: attrs).width) }
    // widest realistic value as the floor, so the item doesn't change width every refresh
    let widths = cols.map { max(width($0.top), width($0.bottom), width("M: 888K")) }
    let gap: CGFloat = 8, h = NSStatusBar.system.thickness
    let size = NSSize(width: widths.reduce(0, +) + gap * CGFloat(cols.count - 1), height: h)
    let image = NSImage(size: size, flipped: false) { _ in
        let lineH = ceil(NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium).boundingRectForFont.height)
        var x: CGFloat = 0
        for (c, w) in zip(cols, widths) {
            (c.top as NSString).draw(at: NSPoint(x: x, y: h / 2 + 0.5), withAttributes: attrs)
            (c.bottom as NSString).draw(at: NSPoint(x: x, y: h / 2 - lineH + 1), withAttributes: attrs)
            NSColor.black.setFill()
            NSRect(x: x, y: h / 2, width: w, height: 0.5).fill()
            x += w + gap
        }
        return true
    }
    image.isTemplate = true
    return image
}

final class App: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
    let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    var rowItems: [NSMenuItem] = []
    var sampler = Sampler()
    var diskValue = disk()
    var tick = 0

    // Homebrew installs into a versioned Cellar path and starts the app via `brew services`,
    // so a login item there would break on upgrade and launch a second copy.
    // resolve symlinks: brew services launches via /opt/homebrew/opt/menustats -> ../Cellar/menustats/<version>
    let viaHomebrew = Bundle.main.bundleURL.resolvingSymlinksInPath().path.contains("/Cellar/")

    func applicationDidFinishLaunching(_ n: Notification) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        log.notice("MenuStats \(version, privacy: .public) started from \(Bundle.main.bundlePath, privacy: .public) (Homebrew: \(self.viaHomebrew))")
        // one copy only (e.g. login item and a manual launch at the same time)
        let me = ProcessInfo.processInfo.processIdentifier
        if let other = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .first(where: { $0.processIdentifier != me }) {
            log.notice("another copy is already running (pid \(other.processIdentifier)); exiting")
            exit(0)
        }
        // register as a login item once; afterwards respect the user's choice (menu or System Settings)
        if !viaHomebrew && !UserDefaults.standard.bool(forKey: "loginSetUp") {
            // only remember success, so a failed registration is retried (and logged) on the next launch
            if setLogin(true) { UserDefaults.standard.set(true, forKey: "loginSetUp") }
        }
        login.target = self
        if viaHomebrew {
            login.title = "Start at login: brew services start menustats"
            login.action = nil
            login.isEnabled = false
        }
        menu.autoenablesItems = false
        item.menu = menu
        update()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.update() }
        RunLoop.main.add(timer, forMode: .common) // keep updating while the menu is open
    }

    @objc func toggleLogin() {
        setLogin(SMAppService.mainApp.status != .enabled)
    }

    @discardableResult
    func setLogin(_ on: Bool) -> Bool {
        let s = SMAppService.mainApp
        do {
            try on ? s.register() : s.unregister()
        } catch {
            log.error("login item \(on ? "registration" : "removal", privacy: .public) failed: \(error, privacy: .public)")
            return false
        }
        let status = [SMAppService.Status.notRegistered: "not registered", .enabled: "enabled",
                      .requiresApproval: "needs approval in System Settings > General > Login Items",
                      .notFound: "not found"][s.status] ?? "unknown"
        log.notice("login item \(on ? "registered" : "removed", privacy: .public); status: \(status, privacy: .public)")
        return true
    }

    func applicationWillTerminate(_ n: Notification) {
        log.notice("MenuStats quitting")
    }

    func update() {
        tick += 1
        if tick % 15 == 0 { diskValue = disk() } // disk changes slowly and the query is not free: every 30 s
        let s = sampler.sample(disk: diskValue)
        item.button?.image = barImage(s.bar)
        item.button?.setAccessibilityLabel(s.spoken)
        log.debug("\(s.spoken, privacy: .public)")

        // rebuild only when the number of rows changes (e.g. an interface appears) so an open menu doesn't flicker
        if rowItems.count != s.rows.count {
            menu.removeAllItems()
            rowItems = s.rows.map { _ in NSMenuItem() }
            for (i, r) in rowItems.enumerated() {
                if i > 0 && s.rows[i].1.isEmpty { menu.addItem(.separator()) }
                r.isEnabled = false
                menu.addItem(r)
            }
            menu.addItem(.separator())
            menu.addItem(login)
            menu.addItem(quit)
        }
        let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let bold = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
        for (r, (label, value)) in zip(rowItems, s.rows) {
            let heading = value.isEmpty
            let text = heading ? label : label.padding(toLength: 22, withPad: " ", startingAt: 0) + value
            // explicit label color so the read-only rows aren't drawn greyed out
            r.attributedTitle = NSAttributedString(string: text, attributes: [.font: heading ? bold : mono, .foregroundColor: NSColor.labelColor])
        }
        if !viaHomebrew { login.state = SMAppService.mainApp.status == .enabled ? .on : .off }
    }
}

if CommandLine.arguments.contains("--once") {
    // CLI check: print one sample and exit
    echoToStderr = true
    var s = Sampler()
    _ = s.sample(disk: nil)
    Thread.sleep(forTimeInterval: 1)
    let r = s.sample(disk: disk())
    print(r.bar.map(\.top).joined(separator: "   "))
    print(r.bar.map(\.bottom).joined(separator: "   "))
    for (label, value) in r.rows { print(value.isEmpty ? label : "  " + label.padding(toLength: 22, withPad: " ", startingAt: 0) + value) }
    print("VoiceOver: \(r.spoken)")
    exit(failing.isEmpty ? 0 : 1)
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
