// k3batt — 验证「读 K3 电量」这套思路能不能套到别的键盘上
// 用法: k3batt [型号] [间隔秒数]
//   型号默认 "Keychron K3"，传别的型号就能测别的键盘
import Foundation
import IOKit.hid

let args = Array(CommandLine.arguments.dropFirst())
let product = args.count >= 1 ? args[0] : "Keychron K3"
let interval = args.count >= 2 ? (Double(args[1]) ?? 30) : 30

let WANT_TRANSPORT = "Bluetooth"
let REPORT_ID: CFIndex = 3

func stamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f.string(from: Date())
}

func findDevice() -> IOHIDDevice? {
    let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(m, nil)
    IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    guard let all = IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice> else { return nil }
    return all.first {
        (IOHIDDeviceGetProperty($0, kIOHIDProductKey as CFString) as? String) == product &&
        (IOHIDDeviceGetProperty($0, kIOHIDTransportKey as CFString) as? String) == WANT_TRANSPORT
    }
}

func readPercent(_ dev: IOHIDDevice) -> Int? {
    var buf = [UInt8](repeating: 0, count: 64)
    var len = CFIndex(64)
    let r = IOHIDDeviceGetReport(dev, kIOHIDReportTypeInput, REPORT_ID, &buf, &len)
    guard r == kIOReturnSuccess, len >= 2 else { return nil }
    return Int(buf[1])
}

print("k3batt — 每 \(Int(interval)) 秒读一次 \(product) (Ctrl-C 退出)")
print("时间       电量   原始")
print("─────────────────────────────")

var last: Int? = nil
while true {
    if let dev = findDevice() {
        if IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess {
            if let pct = readPercent(dev) {
                var buf = [UInt8](repeating: 0, count: 64)
                var len = CFIndex(64)
                _ = IOHIDDeviceGetReport(dev, kIOHIDReportTypeInput, REPORT_ID, &buf, &len)
                let raw = buf.prefix(max(len, 0)).map { String(format: "%02x", $0) }.joined(separator: " ")
                let delta = last.map { pct - $0 } ?? 0
                let arrow = last == nil ? "" : (delta < 0 ? "  ▼\(-delta)" : delta > 0 ? "  ▲\(delta)" : "")
                print("\(stamp())   \(String(format: "%3d", pct))%   \(raw)\(arrow)")
                last = pct
            } else {
                print("\(stamp())    --    读取失败（键盘可能切到了有线模式）")
            }
            IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        } else {
            print("\(stamp())    --    无法打开设备")
        }
    } else {
        print("\(stamp())    --    没找到 \(product)（未连接 / 不在蓝牙模式）")
    }
    fflush(stdout)
    RunLoop.current.run(until: Date().addingTimeInterval(interval))
}
