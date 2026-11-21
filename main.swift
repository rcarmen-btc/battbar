// BattBar — значок батареи в строке меню поверх batt.
// Постоянный предел (по умолчанию 50%) и разовая зарядка до 80/100%:
// дошла до цели — предел сам возвращается к постоянному.
import AppKit
import IOKit.ps

let battPath = "/opt/homebrew/bin/batt"

struct BatteryInfo {
    var pct: Int
    var plugged: Bool
    var charging: Bool
    var charged: Bool
}

func readBattery() -> BatteryInfo? {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
    else { return nil }
    for ps in list {
        guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
              (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType
        else { continue }
        let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 0
        let mx = max(d[kIOPSMaxCapacityKey] as? Int ?? 100, 1)
        return BatteryInfo(
            pct: Int((Double(cur) * 100 / Double(mx)).rounded()),
            plugged: (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue,
            charging: d[kIOPSIsChargingKey] as? Bool ?? false,
            charged: d[kIOPSIsChargedKey] as? Bool ?? false
        )
    }
    return nil
}

struct BatteryHealth {
    var cycles: Int
    var maxMah: Int
    var designMah: Int
    var percent: Int { designMah > 0 ? Int((Double(maxMah) * 100 / Double(designMah)).rounded()) : 0 }
}

/// Циклы и реальная ёмкость из AppleSmartBattery.
func readHealth() -> BatteryHealth? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }
    func int(_ key: String) -> Int? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Int
    }
    guard let cycles = int("CycleCount"),
          let maxMah = int("AppleRawMaxCapacity"),
          let design = int("DesignCapacity")
    else { return nil }
    return BatteryHealth(cycles: cycles, maxMah: maxMah, designMah: design)
}

@discardableResult
func runBatt(_ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: battPath)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

func readLimit() -> Int? {
    let out = runBatt(["status"])
    guard let r = out.range(of: #"Upper limit:\s*(\d+)%"#, options: .regularExpression) else { return nil }
    return Int(out[r].filter(\.isNumber))
}

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    let defaults = UserDefaults.standard
    let queue = DispatchQueue(label: "battbar")
    var battery: BatteryInfo?
    var limit: Int?
    var timer: Timer?

    /// Постоянный предел, к которому возвращаемся после разовой зарядки.
    var base: Int {
        get { let v = defaults.integer(forKey: "base"); return v == 0 ? 50 : v }
        set { defaults.set(newValue, forKey: "base") }
    }
    /// Цель разовой зарядки; 0 — разовой зарядки нет.
    var pending: Int {
        get { defaults.integer(forKey: "pending") }
        set { defaults.set(newValue, forKey: "pending") }
    }
    /// Порог напоминания о зарядке; -1 — выключено, по умолчанию 20%.
    var alertAt: Int {
        get { defaults.object(forKey: "alertAt") == nil ? 20 : defaults.integer(forKey: "alertAt") }
        set { defaults.set(newValue, forKey: "alertAt") }
    }
    /// Сейчас идёт напоминание: от батареи и заряд не выше порога.
    var alerting = false
    var blinkTimer: Timer?
    var blinkOn = false
    var lastSound = Date.distantPast
    /// Тест: `BattBar --test-alert` показывает напоминание сразу.
    let testAlert = CommandLine.arguments.contains("--test-alert")

    func applicationDidFinishLaunching(_ n: Notification) {
        item.button?.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        menu.delegate = self
        item.menu = menu
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() }
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            Unmanaged<App>.fromOpaque(ctx).takeUnretainedValue().refresh()
        }, ctx)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        }
    }

    func refresh() {
        battery = readBattery()
        checkAlert()
        updateTitle()
        queue.async {
            let l = readLimit()
            DispatchQueue.main.async {
                self.limit = l
                self.checkPending()
                self.updateTitle()
            }
        }
    }

    /// Разовая зарядка дошла до цели — вернуть постоянный предел.
    func checkPending() {
        guard pending > 0, let b = battery else { return }
        if b.pct >= pending || (pending == 100 && b.charged) {
            pending = 0
            setLimit(base)
        }
    }

    /// Напоминание: от батареи и заряд ≤ порога — звук (повтор раз в 5 минут) и мигание значка,
    /// пока не подключат зарядку.
    func checkAlert() {
        let should: Bool
        if testAlert {
            should = true
        } else if let b = battery, alertAt > 0 {
            should = !b.plugged && b.pct <= alertAt
        } else {
            should = false
        }
        if should {
            if !alerting {
                alerting = true
                blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    self.blinkOn.toggle()
                    self.updateTitle()
                }
            }
            if Date().timeIntervalSince(lastSound) >= 300 {
                lastSound = Date()
                NSSound(named: "Submarine")?.play()
            }
        } else if alerting {
            alerting = false
            blinkTimer?.invalidate()
            blinkTimer = nil
            blinkOn = false
            lastSound = .distantPast
        }
    }

    func setLimit(_ value: Int) {
        queue.async {
            runBatt(["limit", String(value)])
            DispatchQueue.main.async { self.refresh() }
        }
    }

    func updateTitle() {
        guard let b = battery else { item.button?.title = "—"; return }
        var t = (b.charging ? "⚡︎" : "") + "\(b.pct)%"
        if pending > 0 { t += " → \(pending)" }
        if alerting {
            t = "🔌 " + t
            let color: NSColor = blinkOn ? .systemRed : .labelColor
            item.button?.attributedTitle = NSAttributedString(string: t, attributes: [
                .foregroundColor: color,
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize,
                                                        weight: blinkOn ? .bold : .regular),
            ])
        } else {
            item.button?.title = t
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        battery = readBattery()
        menu.removeAllItems()
        func info(_ s: String) {
            let i = NSMenuItem(title: s, action: nil, keyEquivalent: "")
            i.isEnabled = false
            menu.addItem(i)
        }
        func action(_ s: String, _ sel: Selector, tag: Int = 0, on: Bool = false, enabled: Bool = true) {
            let i = NSMenuItem(title: s, action: enabled ? sel : nil, keyEquivalent: "")
            i.target = self
            i.tag = tag
            i.state = on ? .on : .off
            i.isEnabled = enabled
            menu.addItem(i)
        }

        if let b = battery {
            let state = b.charging ? "заряжается" : (b.plugged ? "от сети, не заряжается" : "от батареи")
            info("Заряд \(b.pct)% · \(state)")
        }
        if let h = readHealth() {
            info("Ёмкость \(h.percent)% (\(h.maxMah) из \(h.designMah) мАч) · циклов \(h.cycles)")
        }
        info("Предел сейчас: " + (limit.map { "\($0)%" } ?? "не прочитан (batt не отвечает)"))
        if pending > 0 { info("Разово до \(pending)%, потом снова \(base)%") }

        menu.addItem(.separator())
        let pct = battery?.pct ?? 0
        for t in [80, 100] {
            action("Один раз до \(t)%", #selector(oneTime(_:)), tag: t,
                   on: pending == t, enabled: pct < t)
        }
        if pending > 0 { action("Отменить разовую зарядку", #selector(cancelOneTime)) }

        menu.addItem(.separator())
        info("Держать всегда:")
        for v in [50, 60, 80, 100] {
            action("   \(v)%", #selector(setBase(_:)), tag: v, on: pending == 0 && base == v)
        }

        menu.addItem(.separator())
        info("Напомнить поставить на зарядку:")
        for v in [20, 30] {
            action("   при \(v)%", #selector(setAlert(_:)), tag: v, on: alertAt == v)
        }
        action("   не напоминать", #selector(setAlert(_:)), tag: -1, on: alertAt <= 0)

        menu.addItem(.separator())
        action("Выйти", #selector(quit))
    }

    @objc func setAlert(_ sender: NSMenuItem) {
        alertAt = sender.tag
        refresh()
    }

    @objc func oneTime(_ sender: NSMenuItem) {
        pending = sender.tag
        setLimit(sender.tag)
    }

    @objc func cancelOneTime() {
        pending = 0
        setLimit(base)
    }

    @objc func setBase(_ sender: NSMenuItem) {
        base = sender.tag
        pending = 0
        setLimit(sender.tag)
    }

    @objc func quit() { NSApp.terminate(nil) }
}

/// `BattBar --print-health` печатает ёмкость и циклы и выходит.
if CommandLine.arguments.contains("--print-health") {
    if let h = readHealth() {
        print("Ёмкость \(h.percent)% (\(h.maxMah) из \(h.designMah) мАч) · циклов \(h.cycles)")
    } else {
        print("Нет данных о батарее")
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
