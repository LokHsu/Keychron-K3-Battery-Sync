import Foundation
import IOKit

/// 把 K3 注册成 accessory power source，让它出现在控制中心「电池」区。
/// 三个符号是 IOKit SPI：导出了但公开头文件没声明，按名字 dlsym 取。
final class PowerSource {

    // MARK: - SPI 签名
    // IOPSCreatePowerSource 只收一个参数（out 指针）。类型由字典里的 "Type" 键决定。
    private typealias CreateFn     = @convention(c) (UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> Int32
    private typealias SetDetailsFn = @convention(c) (UnsafeMutableRawPointer, CFDictionary) -> Int32
    private typealias ReleaseFn    = @convention(c) (UnsafeMutableRawPointer) -> Int32

    private static let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)

    private static func load<T>(_ name: String, as type: T.Type) -> T? {
        guard let iokit, let symbol = dlsym(iokit, name) else { return nil }
        return unsafeBitCast(symbol, to: type)
    }

    private let create     = PowerSource.load("IOPSCreatePowerSource",     as: CreateFn.self)
    private let setDetails = PowerSource.load("IOPSSetPowerSourceDetails", as: SetDetailsFn.self)
    private let release    = PowerSource.load("IOPSReleasePowerSource",    as: ReleaseFn.self)

    /// 不透明句柄，不是 CF 对象；声明成 CFTypeRef 会让 ARC 去 retain，段错误。
    private var handle: UnsafeMutableRawPointer?

    private(set) var lastError: String?

    var isRegistered: Bool { handle != nil }

    deinit { unregister() }

    /// 登记或更新这条电源记录。identifier 必须跨启动稳定（这里用蓝牙地址），
    /// 否则控制中心会把它当成另一个配件反复新建。
    @discardableResult
    func publish(name: String,
                 identifier: String,
                 percent: Int,
                 charging: Bool) -> Bool {
        guard let create, let setDetails else {
            lastError = "IOKit 里找不到 IOPS 符号"
            return false
        }

        if handle == nil {
            var created: UnsafeMutableRawPointer?
            let result = create(&created)
            guard result == kIOReturnSuccess, let created else {
                lastError = String(format: "IOPSCreatePowerSource 失败 (0x%08x)", result)
                return false
            }
            handle = created
        }
        guard let handle else { return false }

        let details: [String: Any] = [
            "Type":                "Accessory Source",
            "Accessory Category":  "Keyboard",
            "Accessory Identifier": identifier,
            "Name":                name,
            "Transport Type":      "Bluetooth",
            "Power Source State":  charging ? "AC Power" : "Battery Power",
            "Current Capacity":    max(0, min(percent, 100)),
            "Max Capacity":        100,
            "Low Warn Level":      20,
            // IOPSKeys.h 规定这两个是 CFBoolean；传 1/0 会被静默接受但充电状态永远不显示。
            "Is Present":          true,
            "Is Charging":         charging,
        ]

        let result = setDetails(handle, details as CFDictionary)
        guard result == kIOReturnSuccess else {
            lastError = String(format: "IOPSSetPowerSourceDetails 失败 (0x%08x)", result)
            return false
        }

        lastError = nil
        return true
    }

    /// 注销。进程退出时本来也会随之消失，显式调用更干净。
    func unregister() {
        guard let handle else { return }
        _ = release?(handle)
        self.handle = nil
    }
}
