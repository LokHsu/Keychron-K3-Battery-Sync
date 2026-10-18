import Foundation
import IOKit.hid

/// 盯 HID 设备树，键盘连上 / 断开立刻回调，不用等轮询。
final class Watcher {

    var onConnect: (() -> Void)?
    var onDisconnect: (() -> Void)?

    /// 必须持有，否则 manager 释放后回调不再来。
    private var manager: IOHIDManager?

    /// 攒着的那次「拆完再看一眼设备树」。
    private var pendingRecheck: DispatchWorkItem?

    /// 上一次问设备树时键盘在不在，用来做边沿触发。
    private var k3Present = false

    @discardableResult
    func start() -> IOReturn {
        guard manager == nil else { return kIOReturnSuccess }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, nil)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, Watcher.matched, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, Watcher.removed, context)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(),
                                        CFRunLoopMode.defaultMode.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

        self.manager = manager
        // 开完先问一次，给 k3Present 一个准数。
        k3Present = hasK3()
        return result
    }

    func stop() {
        guard let manager else { return }
        pendingRecheck?.cancel()
        pendingRecheck = nil
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(),
                                          CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
    }

    deinit { stop() }

    // MARK: - 回调

    private static let matched: IOHIDDeviceCallback = { context, _, _, device in
        guard let watcher = from(context), isK3(device) else { return }
        watcher.k3Present = true
        watcher.onConnect?()
    }

    /// 移除分两种：认得出 → 当场报断开；认不出（节点正在拆、属性全废）→ 攒 0.1 秒再问设备树。
    /// 成批拆除时属性全废，不能把「认不出」当成「就是它」。
    private static let removed: IOHIDDeviceCallback = { context, _, _, device in
        guard let watcher = from(context) else { return }

        if isK3(device) {
            watcher.k3Present = false
            watcher.onDisconnect?()
            return
        }
        watcher.scheduleRecheck()
    }

    // MARK: - 认不出的移除：问设备树

    /// 成批拆除的回调连着来，攒一下并成一次查询。
    private static let settleDelay: TimeInterval = 0.1

    private func scheduleRecheck() {
        pendingRecheck?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.recheckNow() }
        pendingRecheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Watcher.settleDelay, execute: work)
    }

    /// 拆完这一阵，看一眼设备树；键盘真不在了才报断开。
    private func recheckNow() {
        pendingRecheck = nil

        let wasPresent = k3Present
        k3Present = hasK3()

        // 还在 = 虚惊；本来就不在 = 已报过。
        guard wasPresent, !k3Present else { return }
        onDisconnect?()
    }

    /// 现在设备树里有没有那把 K3。问不到也算不在。
    private func hasK3() -> Bool {
        guard let manager,
              let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return false }
        return devices.contains(where: Watcher.isK3)
    }

    private static func from(_ context: UnsafeMutableRawPointer?) -> Watcher? {
        guard let context else { return nil }
        return Unmanaged<Watcher>.fromOpaque(context).takeUnretainedValue()
    }

    private static func product(_ device: IOHIDDevice) -> String? {
        IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String
    }

    private static func isK3(_ device: IOHIDDevice) -> Bool {
        product(device) == K3Reader.productName &&
        (IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String)
            == K3Reader.bluetoothTransport
    }
}
