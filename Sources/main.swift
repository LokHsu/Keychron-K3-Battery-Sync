import AppKit

/// 菜单栏常驻程序：把 Keychron K3 的电量同步进 macOS 电池 UI。
///
/// 编译产物是 K3BatterySyncService，支持 --hide / --show / --debug on|off。
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()

    private let powerSource = PowerSource()
    private let notifier = Notifier()
    private let watcher = Watcher()

    private var lastReading: K3Reading?
    private var lastError: String?
    private var timer: Timer?
    private var pollCount = 0
    /// 必须持有，否则 DispatchSource 释放后不再触发。
    private var signalSources: [DispatchSourceSignal] = []

    private let pollInterval: TimeInterval = 120
    private let lowThreshold = 20

    /// nil = 还没读过。
    private var devicePresent: Bool?
    /// 锁屏时停轮询。
    private var screenLocked = false
    /// 缓存菜单栏按钮状态，用来判断是否隐藏。
    private var menuBarHidden = false
    private var debugLogging = false

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        debugLogging = Prefs.debugLogging
        installSignalHandler()
        requireInputMonitoring()

        notifier.emit = { [weak self] message in self?.say(message) }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        statusItem.menu = menu
        render()

        applyMenuBarVisibility()
        Prefs.observeChanges { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.debugLogging = Prefs.debugLogging
                self.applyMenuBarVisibility()
            }
        }

        startWatchingConnection()
        observeSystemEvents()
    }

    private func startWatchingConnection() {
        watcher.onConnect = { [weak self] in
            self?.say("蓝牙已连上 → 立刻读一次")
            self?.poll()
        }
        watcher.onDisconnect = { [weak self] in
            self?.say("蓝牙已断开 → 立刻确认")
            self?.poll()
        }

        let result = watcher.start()
        if result != kIOReturnSuccess {
            // open 失败不影响设备进出回调，照常跑。
            say(String(format: "⚠️ HID 事件监听没起来 (0x%08x) —— 设备进出回调实测仍会触发", result))
        }
    }

    private func observeSystemEvents() {
        let center = NSWorkspace.shared.notificationCenter

        // 只监听「屏幕唤醒」：整机唤醒总发生在锁屏期间，读不到也看不见。
        let events: [(NSNotification.Name, String)] = [
            (NSWorkspace.screensDidWakeNotification, "屏幕唤醒"),
        ]
        for (name, what) in events {
            _ = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.say("\(what) → 重新读一次")
                self?.poll()
            }
        }

        // 锁屏停轮询、解锁立刻读一次。
        let lockEvents: [(String, Bool)] = [
            ("com.apple.screenIsLocked",   true),
            ("com.apple.screenIsUnlocked", false),
        ]
        for (name, locked) in lockEvents {
            _ = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(name), object: nil, queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.screenLocked = locked
                self.say(locked ? "屏幕已锁定 → 暂停轮询" : "屏幕已解锁 → 立刻读一次")
                self.poll()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        powerSource.unregister()
        say("已退出，小组件键盘电池显示已撤下")
    }

    // MARK: - 终端输出

    /// 调试日志，默认关。
    private func say(_ message: String) {
        guard debugLogging else { return }
        print("\(timeFormatter.string(from: Date()))  \(message)")
        fflush(stdout)
    }

    private func installSignalHandler() {
        signalSources = [SIGINT, SIGTERM].map { sig in
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in self?.shutdown() }
            source.resume()
            return source
        }
    }

    private func shutdown() {
        powerSource.unregister()
        say("已退出，小组件键盘电池显示已撤下")
        exit(0)
    }

    /// 没权限就申请一次然后退出。退出码必须 0，否则 KeepAlive 当成崩溃反复拉起。
    private func requireInputMonitoring() {
        guard !K3Reader.hasInputMonitoring else { return }

        let granted = K3Reader.requestInputMonitoring()
        guard granted || K3Reader.hasInputMonitoring else {
            let why = "缺「输入监控」权限，读不到键盘"
            // 不走 say()（日志默认静默），发系统横幅；blocking 是因为紧接着 exit(0)。
            notifier.announce(title: "K3 Battery Sync",
                              subtitle: "需要输入监控权限",
                              body: "请在系统设置 → 隐私与安全 → 输入监控中开启权限后重新运行。",
                              blocking: true)
            lastError = why
            menuBarHidden = Prefs.menuBarHidden
            writeStatus()
            exit(0)
        }
    }

    // MARK: - 轮询开关

    /// 定时器跟「键盘在不在」「屏幕锁没锁」走；断开或锁屏就停。
    /// 停的是定时器，不是事件驱动的读。
    private func syncPollTimer() {
        if devicePresent == false {
            stopPollTimer("断开期间不再空转，键盘连上时自动继续")
        } else if screenLocked {
            stopPollTimer("锁屏期间不读，解锁时自动继续")
        } else {
            startPollTimer()
        }
    }

    private func startPollTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        say("轮询已开启：每 \(Int(pollInterval)) 秒一次")
    }

    private func stopPollTimer(_ why: String) {
        guard timer != nil else { return }
        timer?.invalidate()
        timer = nil
        say("轮询已暂停 —— \(why)")
    }

    private func poll() {
        pollCount += 1
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let outcome = Result { try K3Reader.read() }
            DispatchQueue.main.async { self.apply(outcome) }
        }
    }

    private func apply(_ outcome: Result<K3Reading, Error>) {
        switch outcome {
        case .success(let reading):
            lastError = nil
            lastReading = reading
            devicePresent = true

            // K3 读不到充电状态：插 USB-C 切到有线、蓝牙链路断，一律报 discharging。
            let charging = false
            let published = powerSource.publish(name: "Keychron K3",
                                                identifier: reading.identifier,
                                                percent: reading.percent,
                                                charging: charging)
            if !published {
                lastError = powerSource.lastError
            }

            let mark = published ? "✓" : "✗ \(lastError ?? "发布失败")"
            say("\(String(format: "%3d", reading.percent))%     \(mark)")

            notifier.check(percent: reading.percent, charging: charging)

        case .failure(let error):
            lastError = (error as? K3Reader.ReadError)?.description ?? error.localizedDescription
            let present = !isDisconnected(error)
            devicePresent = present
            say(present ? " ──     读不到：\(lastError ?? "")"
                        : "键盘不在 HID 设备列表里（蓝牙已断开）")

            // 蓝牙真断了才撤。
            if !present, powerSource.isRegistered {
                powerSource.unregister()
                say("→ 小组件键盘电池显示已撤下")
            }
        }

        render()
        writeStatus()
        syncPollTimer()
    }

    /// `.notFound` = 键盘从 HID 列表消失 = 蓝牙真断了。
    private func isDisconnected(_ error: Error) -> Bool {
        guard let readError = error as? K3Reader.ReadError else { return false }
        if case .notFound = readError { return true }
        return false
    }

    // MARK: - 菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if !K3Reader.hasInputMonitoring {
            let item = NSMenuItem(title: "⚠️ 缺「输入监控」权限 — 点这里去开",
                                  action: #selector(openInputMonitoringSettings),
                                  keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            menu.addItem(.separator())
        }

        menu.addItem(label("连接", connectionText))

        if let reading = lastReading {
            let age = Int(Date().timeIntervalSince(reading.date))
            menu.addItem(label("电量", "\(reading.percent)%"))
            menu.addItem(label("更新于", age < 90 ? "刚刚" : "\(age / 60) 分钟前"))
            menu.addItem(label("标识", reading.identifier))
        } else {
            menu.addItem(label("电量", "—"))
            menu.addItem(label("状态", lastError ?? "还没读到"))
        }

        menu.addItem(.separator())

        let refresh = NSMenuItem(title: "立即刷新", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        let hide = NSMenuItem(title: "隐藏菜单栏图标", action: #selector(hideMenuBarIcon),
                              keyEquivalent: "")
        hide.target = self
        menu.addItem(hide)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private var connectionText: String {
        switch devicePresent {
        case .some(true):  return "已连接"
        case .some(false): return "未连接"
        case nil:          return "未知（还没读到）"
        }
    }

    private func label(_ title: String, _ value: String) -> NSMenuItem {
        let item = NSMenuItem(title: "\(title)：\(value)", action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - 菜单栏标题

    private func render() {
        guard let button = statusItem.button else { return }

        let text: String
        let color: NSColor

        // 颜色只看连接状态，不看「多久没更新」。
        if devicePresent == false {
            text = "K3 未连接"
            color = .secondaryLabelColor
        } else if let reading = lastReading {
            text = "\(reading.percent)%"
            color = reading.percent <= lowThreshold ? .systemRed : .labelColor
        } else {
            text = "K3 —"
            color = .secondaryLabelColor
        }

        button.attributedTitle = NSAttributedString(
            string: text,
            attributes: [.foregroundColor: color]
        )
    }

    // MARK: - 动作

    @objc private func refreshNow() {
        poll()
    }

    /// 隐藏/显示图标，程序照跑。藏起来后恢复只能走终端 show。
    private func applyMenuBarVisibility() {
        let hidden = Prefs.menuBarHidden
        statusItem.isVisible = !hidden
        if hidden != menuBarHidden {
            menuBarHidden = hidden
            say(hidden ? "菜单栏图标已隐藏（程序继续后台跑，./K3BatterySync.sh show 恢复）"
                       : "菜单栏图标已恢复")
        }
        writeStatus()
    }

    @objc private func hideMenuBarIcon() {
        Prefs.menuBarHidden = true
        applyMenuBarVisibility()
    }

    @objc private func openInputMonitoringSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - 状态文件
    // 菜单栏出问题时 UI 看不出所以然，落一份 JSON 到磁盘供诊断。

    private func writeStatus() {
        var status: [String: Any] = [
            "updated": ISO8601DateFormatter().string(from: Date()),
            "poll_count": pollCount,
            "registered_with_control_center": powerSource.isRegistered,
            "input_monitoring": K3Reader.hasInputMonitoring ? "granted" : "denied_or_unknown",
            "menu_bar_hidden": menuBarHidden,
            "screen_locked": screenLocked,
        ]
        if let devicePresent { status["k3_in_hid_device_list"] = devicePresent }
        if let reading = lastReading {
            status["percent"] = reading.percent
            status["identifier"] = reading.identifier
            status["reading_age_seconds"] = Int(Date().timeIntervalSince(reading.date))
        }
        status["last_error"] = lastError ?? NSNull()

        let directory = Prefs.directory

        guard let data = try? JSONSerialization.data(withJSONObject: status,
                                                     options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: directory.appendingPathComponent("status.json"), options: .atomic)
    }
}

// MARK: - 命令行开关
// --hide / --show / --debug 只改偏好文件 + 广播一声就退出。

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.contains("--hide") || arguments.contains("--show") {
    let hidden = arguments.contains("--hide")
    Prefs.menuBarHidden = hidden
    Prefs.broadcastChange()
    print("==> 菜单栏图标\(hidden ? "已隐藏" : "已恢复")")
    exit(0)
}

if let index = arguments.firstIndex(of: "--debug") {
    let value = index + 1 < arguments.count ? arguments[index + 1].lowercased() : ""
    guard value == "on" || value == "off" else {
        print("用法: K3BatterySyncService --debug {on|off}")
        exit(1)
    }
    Prefs.debugLogging = (value == "on")
    Prefs.broadcastChange()
    print("==> 调试日志已\(value == "on" ? "开启" : "关闭")")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
