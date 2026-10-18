import Foundation
import CoreFoundation

/// 落盘的偏好：菜单栏图标藏没藏、调试日志开没开。
enum Prefs {

    /// 改完文件后广播，正在跑的实例收到就重读。
    private static let changedNotification = "com.lokhsu.k3batterysync.prefsChanged"
    private static let menuBarKey = "menu_bar_hidden"
    private static let debugKey = "debug_logging"

    /// 状态文件目录（status.json 也落这里）。
    static let directory: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("K3BatterySync", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private static let file = directory.appendingPathComponent("prefs.json")

    private static func load() -> [String: Any] {
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return json
    }

    /// 改一个键、写回。读-改-写，不是覆盖：整个重写成单键会把别的偏好冲掉。
    private static func store(_ key: String, _ value: Bool) {
        var json = load()
        json[key] = value
        guard let data = try? JSONSerialization.data(withJSONObject: json,
                                                     options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: file, options: .atomic)
    }

    static var menuBarHidden: Bool {
        get { load()[menuBarKey] as? Bool ?? false }
        set { store(menuBarKey, newValue) }
    }

    /// 调试日志开关，默认关。
    static var debugLogging: Bool {
        get { load()[debugKey] as? Bool ?? false }
        set { store(debugKey, newValue) }
    }

    // MARK: - 跨进程通知
    // --show 是另起的短命进程：只改文件 + 广播，让常驻实例去改界面。

    /// 广播「偏好变了」。
    static func broadcastChange() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(changedNotification as CFString),
                                             nil, nil, true)
    }

    /// 听广播。常驻实例启动时调用一次。
    static func observeChanges(_ handler: @escaping () -> Void) {
        observer = handler
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        nil,
                                        { _, _, _, _, _ in Prefs.observer?() },
                                        // 这里收裸 CFString，跟 PostNotification 收 CFNotificationName 不同。
                                        changedNotification as CFString,
                                        nil,
                                        .deliverImmediately)
    }

    /// C 回调不能捕获任何东西，处理器只能挂静态变量上。
    private static var observer: (() -> Void)?
}
