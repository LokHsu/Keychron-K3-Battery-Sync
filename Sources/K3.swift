import Foundation
import IOKit.hid

/// 一次电量读数。
struct K3Reading {
    let percent: Int
    /// 键盘蓝牙地址，用作稳定的 Accessory Identifier。
    let identifier: String
    let date: Date
}

/// 从 Keychron K3 读电量（HID report 3）。
///
/// K3 的 report 3 返回 8 字节：`byte[1]` 是电量，`byte[2..8]` 是蓝牙地址。
/// descriptor 声明 report 3 只有 1 字节，实际多出的 6 字节正好是 BD_ADDR。
enum K3Reader {
    static let productName = "Keychron K3"
    static let bluetoothTransport = "Bluetooth"
    static let reportID: CFIndex = 3

    enum ReadError: Error, CustomStringConvertible {
        case notFound
        case cannotOpen(IOReturn)
        case getReportFailed(IOReturn)
        case shortResponse(Int)

        var description: String {
            switch self {
            case .notFound:
                return "没找到键盘（未连接 / 不在蓝牙模式）"
            case .cannotOpen(let r):
                return String(format: "无法打开设备 (0x%08x)", r)
            case .getReportFailed(let r):
                return String(format: "读取 report 失败 (0x%08x)", r)
            case .shortResponse(let n):
                return "返回数据过短 (\(n) 字节)"
            }
        }
    }

    // MARK: - 输入监控权限

    static var hasInputMonitoring: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// 主动请求一次授权（系统只在没问过时弹窗）。
    @discardableResult
    static func requestInputMonitoring() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    /// 扫设备树找那把 K3。每次新建 manager 重新枚举，拿到全新视图。
    private static func findDevice() -> IOHIDDevice? {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, nil)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

        var devices = copyDevices(manager)
        if devices.isEmpty {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            devices = copyDevices(manager)
        }

        return devices.first {
            (IOHIDDeviceGetProperty($0, kIOHIDProductKey as CFString) as? String) == productName &&
            (IOHIDDeviceGetProperty($0, kIOHIDTransportKey as CFString) as? String) == bluetoothTransport
        }
    }

    /// nil 和空集合作一个意思：这次没问到。
    private static func copyDevices(_ manager: IOHIDManager) -> Set<IOHIDDevice> {
        (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
    }

    /// 读一次电量。键盘不会主动推 report 3，只能问。
    static func read() throws -> K3Reading {
        guard let device = findDevice() else { throw ReadError.notFound }

        let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else { throw ReadError.cannotOpen(openResult) }
        defer { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }

        var buffer = [UInt8](repeating: 0, count: 64)
        var length = CFIndex(buffer.count)
        let result = IOHIDDeviceGetReport(device, kIOHIDReportTypeInput, reportID, &buffer, &length)
        guard result == kIOReturnSuccess else { throw ReadError.getReportFailed(result) }
        guard length >= 2 else { throw ReadError.shortResponse(length) }

        var identifier = "keychron-k3"
        if length >= 8 {
            identifier = (2..<8).map { String(format: "%02x", buffer[$0]) }.joined(separator: ":")
        }

        return K3Reading(percent: min(max(Int(buffer[1]), 0), 100),
                         identifier: identifier,
                         date: Date())
    }
}
