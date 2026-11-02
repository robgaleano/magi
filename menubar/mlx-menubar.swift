import Cocoa

// MARK: - Configuration

let serverBase = "http://127.0.0.1:8080"
let launchLabel = "com.local.mlx-server"
let home = NSHomeDirectory()
let env = ProcessInfo.processInfo.environment
// Install location of the server (set by the LaunchAgent; see menubar/install.sh).
let mlxHome = env["MLX_HOME"] ?? home + "/llm/mlx-qwen38"
let serverPlist = home + "/Library/LaunchAgents/com.local.mlx-server.plist"
let serverLog = mlxHome + "/server.log"
let setupGuide = env["MLX_SETUP_GUIDE"] ?? mlxHome + "/README.md"
// Server API key (docs/security.md). Read on every request so a rotated key is picked up without a restart.
let apiKeyFile = env["MAGI_API_KEY_FILE"] ?? home + "/.config/magi/api-key"
func authorize(_ req: inout URLRequest) {
    guard let key = try? String(contentsOfFile: apiKeyFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return }
    req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
}
let sudoersRule = "/etc/sudoers.d/mlx-iogpu"
let gib = 1_073_741_824.0

enum Status {
    case offline, unloaded, idle, generating(Int), working(String)

    var text: String {
        switch self {
        case .offline: return "Offline"
        case .unloaded: return "Not loaded"
        case .idle: return "Idle"
        case .generating(let n): return n > 1 ? "Generating · \(n)" : "Generating"
        case .working(let s): return s
        }
    }

    var color: NSColor {
        switch self {
        case .offline: return .systemRed
        case .unloaded: return .systemGray
        case .idle: return .systemGreen
        case .generating: return NSColor(srgbRed: 0xF8 / 255.0, green: 0xB0 / 255.0, blue: 0xC8 / 255.0, alpha: 1)
        case .working: return .systemBlue
        }
    }
}

// MARK: - Menu views

final class HeaderView: NSView {
    private let title = NSTextField(labelWithString: "MLX Server")
    private let subtitle = NSTextField(labelWithString: "")
    private let dot = NSImageView()
    private let status = NSTextField(labelWithString: "")

    init(width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 44))
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 11, weight: .medium)
        status.textColor = .secondaryLabelColor
        dot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
        dot.symbolConfiguration = .init(pointSize: 7, weight: .regular)
        for v in [title, subtitle, dot, status] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
            status.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            status.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            dot.trailingAnchor.constraint(equalTo: status.leadingAnchor, constant: -4),
            dot.centerYAnchor.constraint(equalTo: status.centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: dot.leadingAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(model: String, detail: String, status s: Status) {
        title.stringValue = model
        subtitle.stringValue = detail
        status.stringValue = s.text
        dot.contentTintColor = s.color
    }
}

final class InfoRow: NSView {
    private let label = NSTextField(labelWithString: "")
    private let value = NSTextField(labelWithString: "—")

    init(symbol: String, title: String, width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 22))
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        icon.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        label.stringValue = title
        label.font = .systemFont(ofSize: 13)
        value.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        value.textColor = .secondaryLabelColor
        value.alignment = .right
        for v in [icon, label, value] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            value.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            value.centerYAnchor.constraint(equalTo: centerYAnchor),
            value.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 12),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(_ text: String?, color: NSColor = .secondaryLabelColor) {
        value.stringValue = text ?? "—"
        value.textColor = color
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let menuWidth: CGFloat = 300
    var statusItem: NSStatusItem!
    var timer: Timer?
    var busy: String?
    var serverRunning = false
    var modelLoaded = false
    var modelPath = "robgaleano/Swift-1.5-Qwen3.8-27B-MLX-8bit"

    lazy var header = HeaderView(width: menuWidth)
    lazy var decodeRow = InfoRow(symbol: "gauge.with.dots.needle.67percent", title: "Decode", width: menuWidth)
    lazy var prefillRow = InfoRow(symbol: "arrow.down.to.line", title: "Prefill", width: menuWidth)
    lazy var memoryRow = InfoRow(symbol: "memorychip", title: "GPU memory", width: menuWidth)
    lazy var cacheRow = InfoRow(symbol: "square.stack.3d.up", title: "Prompt cache", width: menuWidth)
    lazy var contextRow = InfoRow(symbol: "text.line.first.and.arrowtriangle.forward", title: "Context", width: menuWidth)

    // Context size of the current agent session (docs/clients.md, "Long sessions").
    // Below ctxWarn: full speed. ctxWarn–ctxNew: slower. Above ctxNew: start a new session.
    let ctxWarn = Int(env["MAGI_CTX_WARN"] ?? "") ?? 40_000
    let ctxNew = Int(env["MAGI_CTX_NEW"] ?? "") ?? 80_000
    // Only nag in the menu bar while the session is recent.
    let ctxStaleAfter: TimeInterval = 30 * 60

    let loadItem = NSMenuItem(title: "Load model", action: #selector(toggleModel), keyEquivalent: "l")
    let reasoningItem = NSMenuItem(title: "Reasoning", action: nil, keyEquivalent: "")
    let clearItem = NSMenuItem(title: "Clear prompt cache", action: #selector(clearCache), keyEquivalent: "k")
    let clearDiskItem = NSMenuItem(title: "Clear prompt cache + disk", action: #selector(clearCacheAndDisk), keyEquivalent: "k")
    let serverItem = NSMenuItem(title: "Server", action: nil, keyEquivalent: "")
    let restartItem = NSMenuItem(title: "Restart", action: #selector(restartServer), keyEquivalent: "r")
    let startStopItem = NSMenuItem(title: "Stop", action: #selector(startOrStopServer), keyEquivalent: "")
    let speedTestItem = NSMenuItem(title: "Speed test", action: #selector(speedTest), keyEquivalent: "")
    let memoryLimitItem = NSMenuItem(title: "Enable GPU memory limit…", action: #selector(enableMemoryLimit), keyEquivalent: "")
    var reasoningLevels: [NSMenuItem] = []

    // MARK: Setup

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.toolTip = "MLX Server"
        setBarIcon("brain", dim: true)

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        menu.addItem(viewItem(header))
        menu.addItem(.separator())
        for row in [decodeRow, prefillRow, memoryRow, cacheRow, contextRow] { menu.addItem(viewItem(row)) }
        menu.addItem(.separator())

        configure(loadItem, symbol: "arrow.down.circle")
        menu.addItem(loadItem)

        configure(reasoningItem, symbol: "lightbulb")
        let reasoningMenu = NSMenu()
        for (title, value) in [("Off", "off"), ("Low", "low"), ("Medium", "medium"), ("XHigh", "xhigh")] {
            let item = NSMenuItem(title: title, action: #selector(setReasoning(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            reasoningLevels.append(item)
            reasoningMenu.addItem(item)
        }
        reasoningItem.submenu = reasoningMenu
        menu.addItem(reasoningItem)

        configure(clearItem, symbol: "trash")
        configure(clearDiskItem, symbol: "trash")
        clearDiskItem.keyEquivalentModifierMask = [.command, .option]
        clearDiskItem.isAlternate = true
        menu.addItem(clearItem)
        menu.addItem(clearDiskItem)
        menu.addItem(.separator())

        configure(serverItem, symbol: "server.rack")
        let serverMenu = NSMenu()
        serverMenu.autoenablesItems = false
        configure(restartItem, symbol: "arrow.clockwise")
        configure(startStopItem, symbol: "stop.circle")
        configure(speedTestItem, symbol: "timer")
        serverMenu.addItem(restartItem)
        serverMenu.addItem(startStopItem)
        serverMenu.addItem(.separator())
        serverMenu.addItem(speedTestItem)
        serverMenu.addItem(action("Copy API URL", symbol: "link", #selector(copyApiUrl)))
        serverMenu.addItem(action("Open server log", symbol: "text.alignleft", #selector(openLog)))
        serverItem.submenu = serverMenu
        menu.addItem(serverItem)

        menu.addItem(action("Setup guide", symbol: "book", #selector(openGuide)))
        configure(memoryLimitItem, symbol: "lock.shield")
        menu.addItem(memoryLimitItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit MLX Menu Bar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
        poll()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        if let i = CommandLine.arguments.firstIndex(of: "--snapshot-menu"), i + 1 < CommandLine.arguments.count {
            snapshotMenu(to: CommandLine.arguments[i + 1])
        }
    }

    // `mlx-menubar --snapshot-menu out.png`: opens this app's menu, saves a screenshot of it
    // with screencapture (needs Screen Recording for the launching terminal) and quits.
    // Used to regenerate assets/menubar-dropdown.png.
    func snapshotMenu(to path: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            let capture = Timer(timeInterval: 1.5, repeats: false) { [weak self] _ in
                let pid = Int(ProcessInfo.processInfo.processIdentifier)
                let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
                let menuWindow = windows
                    .filter { ($0[kCGWindowOwnerPID as String] as? Int) == pid && ($0[kCGWindowLayer as String] as? Int ?? 0) > 0 }
                    .max { a, b in
                        let ra = a[kCGWindowBounds as String] as? [String: Double] ?? [:]
                        let rb = b[kCGWindowBounds as String] as? [String: Double] ?? [:]
                        return (ra["Width"] ?? 0) * (ra["Height"] ?? 0) < (rb["Width"] ?? 0) * (rb["Height"] ?? 0)
                    }
                if let id = menuWindow?[kCGWindowNumber as String] as? Int {
                    let task = Process()
                    task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    task.arguments = ["-x", "-o", "-l", String(id), path]
                    try? task.run()
                    task.waitUntilExit()
                } else {
                    FileHandle.standardError.write("menu window not found\n".data(using: .utf8)!)
                }
                self?.statusItem.menu?.cancelTracking()
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
            RunLoop.main.add(capture, forMode: .common)
            self.statusItem.button?.performClick(nil)
        }
    }

    func viewItem(_ view: NSView) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = view
        return item
    }

    func configure(_ item: NSMenuItem, symbol: String) {
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: item.title)
    }

    func action(_ title: String, symbol: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        configure(item, symbol: symbol)
        return item
    }

    func menuWillOpen(_ menu: NSMenu) { poll() }

    // MARK: Menu bar icon (monochrome, stacked label)

    // While generating, the brain is tinted and pulses; everything else stays a monochrome template.
    // Sampled from Apple's 🧠 emoji (dominant tone #F8B0C8).
    let pulseColor = NSColor(srgbRed: 0xF8 / 255.0, green: 0xB0 / 255.0, blue: 0xC8 / 255.0, alpha: 1)
    let pulsePeriod: TimeInterval = 1.6
    var pulseTimer: Timer?
    var pulseStart = Date()
    var pulseValue = "…"
    var pulseLabel = "TOK/S"

    func setBarIcon(_ symbol: String, label: String? = nil, value: String? = nil, dim: Bool = false,
                    tint: NSColor? = nil, alpha: CGFloat = 1) {
        guard let button = statusItem.button,
              let base = NSImage(systemSymbolName: symbol, accessibilityDescription: "MLX") else { return }
        var config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        if let tint { config = config.applying(.init(paletteColors: [tint])) }
        guard let sym = base.withSymbolConfiguration(config) else { return }

        let isDark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let textColor: NSColor = tint == nil ? .black : (isDark ? .white : .black)
        let height: CGFloat = 22
        let labelAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 7, weight: .semibold), .foregroundColor: textColor]
        let valueAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold), .foregroundColor: textColor]
        var textWidth: CGFloat = 0
        var labelSize = NSSize.zero, valueSize = NSSize.zero
        if let l = label, let v = value {
            labelSize = (l as NSString).size(withAttributes: labelAttrs)
            valueSize = (v as NSString).size(withAttributes: valueAttrs)
            textWidth = max(labelSize.width, valueSize.width)
        }
        let gap: CGFloat = textWidth > 0 ? 4 : 0
        let size = NSSize(width: ceil(sym.size.width + gap + textWidth), height: height)
        let image = NSImage(size: size, flipped: false) { _ in
            sym.draw(in: NSRect(x: 0, y: (height - sym.size.height) / 2, width: sym.size.width, height: sym.size.height),
                     from: .zero, operation: .sourceOver, fraction: dim ? 0.4 : alpha)
            if let l = label, let v = value {
                let x = sym.size.width + gap
                (l as NSString).draw(at: NSPoint(x: x + (textWidth - labelSize.width) / 2, y: 13), withAttributes: labelAttrs)
                (v as NSString).draw(at: NSPoint(x: x + (textWidth - valueSize.width) / 2, y: -0.5), withAttributes: valueAttrs)
            }
            return true
        }
        image.isTemplate = tint == nil
        button.image = image
        button.title = ""
    }

    func drawPulse() {
        let phase = Date().timeIntervalSince(pulseStart) / pulsePeriod * 2 * .pi
        let alpha = 0.35 + 0.65 * (0.5 + 0.5 * cos(phase))
        setBarIcon("brain.fill", label: pulseLabel, value: pulseValue, tint: pulseColor, alpha: alpha)
    }

    func startPulse(label: String = "TOK/S", value: String) {
        pulseLabel = label
        pulseValue = value
        guard pulseTimer == nil else { return }
        pulseStart = Date()
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.drawPulse() }
        RunLoop.main.add(t, forMode: .common)
        pulseTimer = t
        drawPulse()
    }

    func stopPulse() {
        pulseTimer?.invalidate()
        pulseTimer = nil
    }

    // MARK: Polling

    func poll() {
        guard let url = URL(string: serverBase + "/v1/metrics") else { return }
        var req = URLRequest(url: url)
        authorize(&req)
        req.timeoutInterval = 1.2
        URLSession.shared.dataTask(with: req) { [weak self] data, _, err in
            let root = (err == nil ? data : nil).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            DispatchQueue.main.async { self?.render(root) }
        }.resume()
    }

    func render(_ root: [String: Any]?) {
        memoryLimitItem.isHidden = FileManager.default.fileExists(atPath: sudoersRule)

        guard let root = root else {
            serverRunning = false
            modelLoaded = false
            let status: Status = busy.map { .working($0) } ?? .offline
            header.update(model: "MLX Server", detail: "\(serverBase) not responding", status: status)
            for row in [decodeRow, prefillRow, memoryRow, cacheRow, contextRow] { row.set(nil) }
            stopPulse()
            setBarIcon(busy != nil ? "hourglass" : "brain", dim: busy == nil)
            if busy == nil { syncMemoryLimit(loaded: false, current: readWiredLimitMB()) }
            updateActions()
            return
        }

        let summary = root["summary"] as? [String: Any] ?? [:]
        let latest = root["latest"] as? [String: Any] ?? [:]
        let server = root["server"] as? [String: Any] ?? [:]
        let apc = server["apc"] as? [String: Any] ?? [:]
        let mem = server["mlx_memory"] as? [String: Any] ?? [:]
        let live = root["live"] as? [String: Any] ?? [:]
        let liveDecode = live["decode_tok_s"] as? Double ?? 0
        // Prompt still being read (prefill): show its progress instead of a speed.
        let livePrefill = (live["prefill"] as? [[String: Any]])?.first
        let prefillPercent = livePrefill?["percent"] as? Double
        let prefillTotal = livePrefill?["total"] as? Int ?? 0

        serverRunning = true
        let loaded = server["loaded_model"] as? String
        modelLoaded = loaded != nil
        let inFlight = summary["in_flight"] as? Int ?? 0
        if let path = loaded ?? (mem["default_model"] as? String) { modelPath = path }
        let modelName = displayName(modelPath)
        let hasDrafter = (mem["draft_model"] as? String) != nil

        let effort = (mem["reasoning_effort"] as? String ?? "medium").lowercased()
        for item in reasoningLevels {
            let value = item.representedObject as? String
            item.state = (value == effort || (value == "xhigh" && effort == "high")) ? .on : .off
        }
        let effortTitle = reasoningLevels.first { $0.state == .on }?.title ?? effort
        reasoningItem.badge = NSMenuItemBadge(string: effortTitle)

        let decode = max(latest["decode_tok_s"] as? Double ?? 0, latest["sliding_decode_tok_s_last_32"] as? Double ?? 0)
        let prefill = latest["prefill_tok_s"] as? Double ?? 0
        let active = (mem["active_bytes"] as? Double ?? 0) / gib
        let wiredMB = mem["iogpu_wired_limit_mb"] as? Int ?? 0
        let apcUsed = (apc["resident_bytes"] as? Double ?? 0) / gib
        let apcMax = (apc["memory_max_bytes"] as? Double ?? 0) / gib

        let generating = inFlight > 0 && busy == nil && modelLoaded
        let shownDecode = generating && liveDecode > 0 ? liveDecode : decode
        decodeRow.set(shownDecode > 0 ? String(format: "%.1f tok/s", shownDecode) : nil)
        if generating, liveDecode == 0, let pct = prefillPercent {
            prefillRow.set(String(format: "%.0f%% of %@ tokens", pct, grouped(Double(prefillTotal))))
        } else {
            prefillRow.set(prefill > 0 ? "\(grouped(prefill)) tok/s" : nil)
        }
        if modelLoaded {
            memoryRow.set(wiredMB > 0 ? String(format: "%.1f / %.0f GiB", active, Double(wiredMB) / 1024) : String(format: "%.1f GiB", active))
            cacheRow.set(apcMax > 0 ? String(format: "%.1f / %.0f GiB", apcUsed, apcMax) : nil)
        } else {
            memoryRow.set(nil)
            cacheRow.set(nil)
        }

        let status: Status
        if let b = busy { status = .working(b) }
        else if !modelLoaded { status = .unloaded }
        else if inFlight > 0 { status = .generating(inFlight) }
        else { status = .idle }

        let detail = hasDrafter ? "8-bit · MTP drafter" : "8-bit"
        header.update(model: modelName, detail: detail, status: status)

        let ctx = contextSize(recent: root["recent"] as? [[String: Any]] ?? [], prefillTotal: generating ? prefillTotal : 0)
        var ctxAlert: String?
        if modelLoaded, let ctx {
            let label = compactTokens(ctx.tokens)
            if ctx.age >= ctxStaleAfter {
                // Session ended a while ago: show it as history, not as a warning.
                let f = DateFormatter()
                f.dateFormat = "HH:mm"
                let when = f.string(from: Date(timeIntervalSinceNow: -ctx.age))
                contextRow.set("last session \(label) · \(when)")
            } else if ctx.tokens >= ctxNew {
                contextRow.set("\(label) · start new session", color: .systemRed)
                if ctx.age < ctxStaleAfter { ctxAlert = "\(ctx.tokens / 1000)K" }
            } else if ctx.tokens >= ctxWarn {
                contextRow.set("\(label) · getting slower", color: .systemOrange)
            } else {
                contextRow.set(label, color: .systemGreen)
            }
        } else {
            contextRow.set(nil)
        }

        if case .generating = status {
            if liveDecode == 0, let pct = prefillPercent {
                startPulse(label: "PROMPT", value: String(format: "%.0f%%", pct))
            } else {
                startPulse(value: liveDecode > 0 ? String(format: "%.1f", liveDecode) : "…")
            }
        } else {
            stopPulse()
            switch status {
            case .working: setBarIcon("hourglass")
            case .unloaded: setBarIcon("brain", dim: true)
            default:
                if let alert = ctxAlert {
                    setBarIcon("brain.fill", label: "CONTEXT", value: alert, tint: .systemOrange)
                } else {
                    setBarIcon("brain.fill")
                }
            }
        }
        syncMemoryLimit(loaded: modelLoaded, current: wiredMB)
        updateActions()
    }

    func updateActions() {
        let ready = serverRunning && busy == nil
        loadItem.isEnabled = ready
        loadItem.title = modelLoaded ? "Unload model" : "Load model"
        loadItem.keyEquivalent = modelLoaded ? "u" : "l"
        loadItem.image = NSImage(systemSymbolName: modelLoaded ? "eject" : "arrow.down.circle", accessibilityDescription: nil)
        reasoningItem.isEnabled = ready
        clearItem.isEnabled = ready && modelLoaded
        clearDiskItem.isEnabled = ready
        speedTestItem.isEnabled = ready
        restartItem.isEnabled = busy == nil
        startStopItem.isEnabled = busy == nil
        startStopItem.title = serverRunning ? "Stop" : "Start"
        startStopItem.image = NSImage(systemSymbolName: serverRunning ? "stop.circle" : "play.circle", accessibilityDescription: nil)
    }

    func displayName(_ path: String) -> String {
        let name = path.components(separatedBy: "/").last ?? path
        return name.replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: " 8bit", with: "")
            .replacingOccurrences(of: " MLX", with: "")
    }

    // Agents also send small side requests (titles, summaries), so the session size is the
    // largest prompt among requests finished within 2 minutes of the newest one, or the
    // prompt currently being read if that is larger.
    func contextSize(recent: [[String: Any]], prefillTotal: Int) -> (tokens: Int, age: TimeInterval)? {
        let done = recent.compactMap { r -> (t: Double, n: Int)? in
            guard let t = (r["timestamp_unix"] as? NSNumber)?.doubleValue,
                  let n = (r["prompt_tokens"] as? NSNumber)?.intValue else { return nil }
            return (t, n)
        }
        let now = Date().timeIntervalSince1970
        guard let newest = done.map(\.t).max() else {
            return prefillTotal > 0 ? (prefillTotal, 0) : nil
        }
        let session = done.filter { newest - $0.t <= 120 }.map(\.n).max() ?? 0
        if prefillTotal > session { return (prefillTotal, 0) }
        return (session, prefillTotal > 0 ? 0 : now - newest)
    }

    func compactTokens(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fK tokens", Double(n) / 1000) : "\(n) tokens"
    }

    func grouped(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: value)) ?? String(format: "%.0f", value)
    }

    // MARK: GPU memory limit (16 GiB kept for macOS)

    // The server sets this on load/unload; this is a safety net (e.g. after a reboot,
    // where sysctl values reset) so the limit always matches whether the model is loaded.
    // Total unified memory minus 16 GiB for macOS (114688 MB on a 128 GB Mac); MLX_IOGPU_WIRED_LIMIT_MB overrides it.
    let gpuLimitMB = Int(env["MLX_IOGPU_WIRED_LIMIT_MB"] ?? "") ?? Int(ProcessInfo.processInfo.physicalMemory / 1_048_576) - 16384
    var lastLimitAttempt = Date.distantPast

    func readWiredLimitMB() -> Int {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/sysctl")
        task.arguments = ["-n", "iogpu.wired_limit_mb"]
        task.standardOutput = pipe
        try? task.run()
        task.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    func syncMemoryLimit(loaded: Bool, current: Int) {
        guard busy == nil, FileManager.default.fileExists(atPath: sudoersRule) else { return }
        let wanted = loaded ? gpuLimitMB : 0
        guard current != wanted, Date().timeIntervalSince(lastLimitAttempt) > 30 else { return }
        lastLimitAttempt = Date()
        DispatchQueue.global(qos: .utility).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            task.arguments = ["-n", "/usr/sbin/sysctl", "-w", "iogpu.wired_limit_mb=\(wanted)"]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            try? task.run()
            task.waitUntilExit()
        }
    }

    // MARK: Actions

    func beginBusy(_ label: String) {
        busy = label
        render(nil)
        poll()
    }

    func endBusy() {
        busy = nil
        poll()
    }

    func post(_ path: String, body: [String: Any] = [:], timeout: TimeInterval = 60, busyLabel: String? = nil) {
        guard let url = URL(string: serverBase + path) else { return }
        if let label = busyLabel { beginBusy(label) }
        var req = URLRequest(url: url)
        authorize(&req)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req) { [weak self] _, _, _ in
            DispatchQueue.main.async { busyLabel != nil ? self?.endBusy() : self?.poll() }
        }.resume()
    }

    func shell(_ command: String, busyLabel: String) {
        beginBusy(busyLabel)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/bash")
            task.arguments = ["-c", command]
            try? task.run()
            task.waitUntilExit()
            DispatchQueue.main.async { self?.endBusy() }
        }
    }

    @objc func toggleModel() {
        if modelLoaded { post("/unload", busyLabel: "Unloading…") }
        else { post("/load", timeout: 300, busyLabel: "Loading…") }
    }

    @objc func setReasoning(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        post("/v1/reasoning-effort", body: ["effort": value])
    }

    @objc func clearCache() { post("/v1/cache/reset") }
    @objc func clearCacheAndDisk() { post("/v1/cache/reset?include_disk=true") }

    // The server runs under launchd with KeepAlive, so it must be controlled through launchctl:
    // killing the process would just make launchd restart it.
    var launchTarget: String { "gui/\(getuid())/\(launchLabel)" }

    func waitForHealth(_ seconds: Int) -> String {
        "for i in $(seq 1 \(seconds)); do curl -sf -H @<(printf 'Authorization: Bearer %s\\n' \"$(tr -d '[:space:]' < '\(apiKeyFile)' 2>/dev/null)\") \(serverBase)/health >/dev/null 2>&1 && break; sleep 1; done"
    }

    @objc func restartServer() {
        shell("""
        if launchctl print \(launchTarget) >/dev/null 2>&1; then
          launchctl kickstart -k \(launchTarget)
        else
          launchctl bootstrap gui/$(id -u) "\(serverPlist)"
        fi
        \(waitForHealth(45))
        """, busyLabel: "Restarting…")
    }

    @objc func startOrStopServer() {
        if serverRunning {
            shell("""
            launchctl bootout \(launchTarget) 2>/dev/null || true
            sudo -n /usr/sbin/sysctl -w iogpu.wired_limit_mb=0 >/dev/null 2>&1 || true
            """, busyLabel: "Stopping…")
        } else {
            shell("""
            launchctl print \(launchTarget) >/dev/null 2>&1 || launchctl bootstrap gui/$(id -u) "\(serverPlist)"
            launchctl kickstart \(launchTarget) 2>/dev/null || true
            \(waitForHealth(45))
            """, busyLabel: "Starting…")
        }
    }

    @objc func speedTest() {
        post("/v1/chat/completions", body: [
            "model": modelPath,
            "messages": [["role": "user", "content": "Write a Python binary search function with type hints and a short docstring."]],
            "max_tokens": 256,
            "temperature": 0,
            "reasoning_effort": "off",
        ], timeout: 300, busyLabel: "Speed test…")
    }

    @objc func enableMemoryLimit() {
        let script = """
        do shell script "printf '%s\\\\n' '\(NSUserName()) ALL=(root) NOPASSWD: /usr/sbin/sysctl -w iogpu.wired_limit_mb=\(gpuLimitMB), /usr/sbin/sysctl -w iogpu.wired_limit_mb=0' > \(sudoersRule) && chmod 0440 \(sudoersRule) && visudo -cf \(sudoersRule) && /usr/sbin/sysctl -w iogpu.wired_limit_mb=\(gpuLimitMB)" with administrator privileges
        """
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", script]
            try? task.run()
            task.waitUntilExit()
            DispatchQueue.main.async { self?.poll() }
        }
    }

    @objc func copyApiUrl() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(serverBase + "/v1", forType: .string)
    }

    @objc func openLog() { NSWorkspace.shared.open(URL(fileURLWithPath: serverLog)) }
    @objc func openGuide() { NSWorkspace.shared.open(URL(fileURLWithPath: setupGuide)) }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
