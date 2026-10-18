import Foundation

/// 系统横幅：低电量提醒（跨阈值报一次、回升重新武装）+ 一次性原因的单发通知。
///
/// 走 osascript，不用 UNUserNotificationCenter（后者要求打包成 .app）。
/// 代价是署名「脚本编辑器」。文本从 argv 传，省掉转义。
final class Notifier {

    /// 从高到低，跨过哪个报哪个。
    private let thresholds = [20, 10]
    private var alreadyNotified: Set<Int> = []

    var emit: ((String) -> Void)?

    func check(percent: Int, charging: Bool) {
        // 充电中不打扰，并重新武装阈值。
        if charging {
            alreadyNotified.removeAll()
            return
        }

        // 电量回升时重新武装。
        alreadyNotified = alreadyNotified.filter { percent <= $0 }

        for threshold in thresholds where percent <= threshold && !alreadyNotified.contains(threshold) {
            alreadyNotified.insert(threshold)
            post(percent: percent, threshold: threshold)
            break   // 一次只报最相关的那个
        }
    }

    private func post(percent: Int, threshold: Int) {
        showBanner(title: "Keychron K3",
                   body: "电量剩余 \(percent)%")
    }

    /// 单发一条横幅，不走阈值状态机。给「起不来」这类一次性原因用。
    /// blocking 时在调用线程跑完再返回——紧接着 exit() 的场合必须用它。
    func announce(title: String, subtitle: String = "", body: String, blocking: Bool = false) {
        showBanner(title: title, body: body, subtitle: subtitle, blocking: blocking)
    }

    private func showBanner(title: String, body: String, subtitle: String = "", blocking: Bool = false) {
        let script = """
            on run argv
                display notification (item 1 of argv) with title (item 2 of argv) subtitle (item 3 of argv) sound name "Basso"
            end run
            """
        // argv 顺序：body、title、subtitle。
        let argv = ["-e", script, body, title, subtitle]

        let run = { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = argv

            do {
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus != 0 else { return }
                self?.report("横幅发不出去：osascript 退出码 \(process.terminationStatus)")
            } catch {
                self?.report("横幅发不出去：\(error.localizedDescription)")
            }
        }

        if blocking {
            run()
        } else {
            DispatchQueue.global(qos: .utility).async(execute: run)
        }
    }

    private func report(_ message: String) {
        DispatchQueue.main.async { [weak self] in self?.emit?(message) }
    }
}
