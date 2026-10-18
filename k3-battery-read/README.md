# k3batt —— 验证 K3 的读取思路能不能套到别的键盘

主程序只针对 Keychron K3。这个小工具用来回答一个问题：**K3 读电量的思路（蓝牙经典 HID 的 report 3，`byte[1]` 是百分比），能不能用到别的键盘上。**

```bash
swiftc -swift-version 5 poll.swift -o k3batt
./k3batt                    # 默认测 Keychron K3，30 秒一次
./k3batt "Keychron K3"      # 测 K3
./k3batt "Keychron K3" 5    # 测 K3，5 秒一次
```

型号名要和「系统信息 → 蓝牙」里显示的一致。

```
k3batt — 每 30 秒读一次 Keychron K3 (Ctrl-C 退出)
时间       电量   原始
─────────────────────────────
23:14:54    40%   03 28 dc 2c 26 38 05 28
```

- 读到百分比 → 这台键盘走的也是 report 3，K3 的思路能复用
- 读不到 → 打印原因（没找到 / 打不开 / 读取失败），大概率这个型号没上报电量，或上报方式不一样

> 终端会继承「输入监控」授权；装成 LaunchAgent 后服务还得单独开授权。
