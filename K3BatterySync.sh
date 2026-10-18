#!/bin/bash
# K3BatterySync.sh —— K3 Battery Sync 的控制面板
#
#   ./K3BatterySync.sh install     装成登录自启（LaunchAgent）并立即启动
#   ./K3BatterySync.sh uninstall   卸掉自启（会问一句要不要顺手删掉授权）
#   ./K3BatterySync.sh start       重新开始
#   ./K3BatterySync.sh restart     重启（改完权限用它）
#   ./K3BatterySync.sh status      看状态
#   ./K3BatterySync.sh stop        停掉，并且不再自启
#
#   ./K3BatterySync.sh hide        隐藏菜单栏图标（程序继续后台跑）
#   ./K3BatterySync.sh show        恢复菜单栏图标
#
#   ./K3BatterySync.sh debug on    开始往日志里写（默认关，日志平时为空）
#   ./K3BatterySync.sh debug off   停止写日志
#
# 名字分三层：
#   K3 Battery Sync         产品名
#   K3BatterySync.sh        ← 本脚本，你敲的入口
#   K3BatterySyncService    编译出来的二进制，launchd 拉的就是它
#
# ⚠️ install 完还差一步：给它「输入监控」权限，否则读不到键盘。
#    见下方 install 输出的说明。
set -euo pipefail
cd "$(dirname "$0")"

LABEL="com.lokhsu.k3batterysync"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
BIN="$(pwd)/K3BatterySyncService"
# 正常输出 + 崩溃 stderr 都进这一个文件。
LOG="$HOME/Library/Logs/k3batterysync.log"

DOMAIN="gui/$(id -u)"

INPUT_MONITORING_PANE="x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"

need_binary() {
    [ -x "$BIN" ] || { echo "✗ 还没有 ${BIN}，先跑 ./build.sh" >&2; exit 1; }
}

install() {
    need_binary

    mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"

    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>StandardOutPath</key>
    <string>$LOG</string>
</dict>
</plist>
EOF

    restart
    echo
    echo "==> 已装好: $PLIST"
    echo "==> 日志:   $LOG"
    echo
    echo "⚠️  还差一步 —— 开「输入监控」权限，否则读不到键盘："
    echo "    服务启动会自己弹窗申请，点「打开系统设置」→ 隐私与安全性 → 输入监控"
    echo "    把 K3BatterySyncService 打开，再跑 ./K3BatterySync.sh restart"
    echo "    没弹窗 / 重编译过就手动加：删旧条目 → + → ⌘⇧G 粘贴 $BIN"
    echo "    （没授权时服务会自己退出，不会空转）"
    echo
}

restart() {
    need_binary

    # 先 enable——disable 过的 job 直接 bootstrap 会被 launchd 拒掉。
    launchctl enable "$DOMAIN/$LABEL"

    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true

    # bootout 之后马上 bootstrap 会撞 "Input/output error"，等一下重试。
    for _ in 1 2 3 4 5; do
        if launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null; then
            echo "==> 已启动"
            return
        fi
        sleep 1
    done

    echo "✗ 启动失败，手动看看：launchctl print $DOMAIN/$LABEL" >&2
    exit 1
}

# 停掉并保持停：bootout 卸 job，disable 记住别自启（跨重启有效）。
stop() {
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    launchctl disable "$DOMAIN/$LABEL"
    echo "==> 已停：进程退出，控制中心那条同时撤下"
    echo "    不会再自启（跨重启有效），「输入监控」授权留着没动"
    echo "    重新开始：./K3BatterySync.sh start"
}

start() {
    need_binary
    [ -f "$PLIST" ] || { echo "✗ 还没安装自启动文件，先跑 ./K3BatterySync.sh install" >&2; exit 1; }
    restart
}

# osascript 弹窗问要不要去删授权；点「以后再说」退出码非 0，用 `|| true` 兜住 set -e。
ask_remove_grant() {
    local answer
    answer=$(osascript \
        -e 'on run argv' \
        -e 'display dialog (item 1 of argv) with title (item 2 of argv) buttons {"打开设置", "以后再说"} default button "打开设置" with icon caution' \
        -e 'return button returned of result' \
        -e 'end run' \
        $'K3 Battery Sync 已卸载\n\n是否立即移除 K3BatterySyncService 的"输入监控"权限？' \
        "K3 Battery Sync") || true

    if [ "$answer" = "打开设置" ]; then
        echo "==> 已打开「输入监控」—— 选中 K3BatterySyncService，按 − 删掉"
        open "$INPUT_MONITORING_PANE"
    elif [ -z "$answer" ]; then
        echo "    （没开设置 —— 要删那条授权的话手动开 System Settings → Privacy & Security → 输入监控）"
    fi
}

uninstall() {
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "==> 已卸载（日志留在 ${LOG}）"
    ask_remove_grant
}

status() {
    if launchctl print-disabled "$DOMAIN" 2>/dev/null \
        | grep -q "\"${LABEL}\"[[:space:]]*=>[[:space:]]*disabled"; then
        echo "LaunchAgent: 已停用（不会自启 —— ./K3BatterySync.sh start 恢复）"
    elif launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
        echo "LaunchAgent: 已加载"
    else
        echo "LaunchAgent: 未加载"
    fi
    echo -n "进程:        "; pgrep -fl K3BatterySyncService || echo "(没在跑)"
    echo
    echo "状态文件:"
    cat "$HOME/Library/Application Support/K3BatterySync/status.json" 2>/dev/null | sed 's/^/  /' \
        || echo "  (还没有)"
}

hide() { need_binary; "$BIN" --hide; }
show() { need_binary; "$BIN" --show; }

debug() {
    case "${1:-}" in
        on|off) need_binary; "$BIN" --debug "$1" ;;
        *) echo "用法: $0 debug {on|off}" >&2; exit 1 ;;
    esac
}

case "${1:-}" in
    install)   install ;;
    restart)   restart ;;
    stop)      stop ;;
    start)     start ;;
    uninstall) uninstall ;;
    status)    status ;;
    hide)      hide ;;
    show)      show ;;
    debug)     debug "${2:-}" ;;
    *)
        echo "用法: $0 {install|restart|stop|start|status|uninstall|hide|show|debug on|debug off}" >&2
        exit 1
        ;;
esac
