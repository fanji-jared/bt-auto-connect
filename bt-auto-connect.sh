#!/usr/bin/env bash
#
# bluetooth-auto-connect.sh
# ---------------------------------------------------------------------------
# 面向 Orange Pi / ARM SBC 的蓝牙键鼠自动连接守护脚本
#
# 功能：
#   1. 默认从 Blueman「最近连接」缓存读取目标设备列表（按 MAC 直连）
#   2. 缓存为空时回退到手动维护列表（支持 名称 / MAC / 名称+MAC 三种条目）
#   3. 同名多设备按 RSSI 信号强度择优连接
#   4. 单次扫描最长 5 分钟，全部连上即提前退出
#   5. 无参数运行 = 安装向导（自动装 systemd 开机自启）
#
# 适用场景：
#   蓝牙适配器每次重启 MAC 随机、BlueZ 配对库无法跨重启保留的 SBC
#   （例如 Orange Pi 3B + RTL8761B 模组）
# ---------------------------------------------------------------------------
set -euo pipefail

# ---------- 配置区 ----------
SCRIPT_NAME="bt-auto-connect"
SCRIPT_GLOBAL_PATH="/usr/local/bin/${SCRIPT_NAME}"
SERVICE_NAME="${SCRIPT_NAME}.service"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"
MANUAL_LIST="/etc/bt_autoconnect_devices.list"
BLUEMAN_GSET="org.blueman.plugins.recentconns"
BLUEMAN_KEY="recent-connections"
MAX_SECONDS=300          # 单次 run 最大扫描时长（5 分钟）
SCAN_SECONDS=2           # 每轮扫描窗口（秒）
INTERVAL=3               # 轮询间隔（秒）
MAC_REGEX='^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$'
# ----------------------------

CURR_USER="${SUDO_USER:-$USER}"
USER_UID="$(id -u "$CURR_USER")"

# ---------- 彩色输出 ----------
c_info() { echo -e "\033[36m[INFO]\033[0m  $*"; }
c_ok()   { echo -e "\033[32m[ OK ]\033[0m  $*"; }
c_warn() { echo -e "\033[33m[WARN]\033[0m  $*"; }
c_err()  { echo -e "\033[31m[ERR ]\033[0m  $*"; }

# ---------- 依赖检查 ----------
check_deps() {
    local miss=()
    command -v bluetoothctl >/dev/null 2>&1 || miss+=("bluez (bluetoothctl)")
    command -v gsettings    >/dev/null 2>&1 || miss+=("libglib2.0-bin (gsettings)")
    command -v python3       >/dev/null 2>&1 || miss+=("python3")
    if [ ${#miss[@]} -gt 0 ]; then
        c_err "缺少依赖：${miss[*]}"
        c_info "安装命令：sudo apt install bluez blueman python3 libglib2.0-bin"
        exit 1
    fi
}

# 判断是否已经安装过
is_installed() {
    [ -f "$SCRIPT_GLOBAL_PATH" ] && systemctl list-unit-files 2>/dev/null | grep -q "$SERVICE_NAME"
}

# ===========================================================================
# Blueman 缓存读取
# gsettings 里 recent-connections 是一个 dict 数组，形如：
#   [{'adapter': '..', 'address': 'AA:BB:..', 'alias': 'GPW G3', ...}, ...]
# 这里只抽 alias + address 两列输出，用 TAB 分隔
# ===========================================================================
read_blueman_pairs() {
    if ! gsettings list-schemas 2>/dev/null | grep -q "$BLUEMAN_GSET"; then
        return 1
    fi
    gsettings get "$BLUEMAN_GSET" "$BLUEMAN_KEY" 2>/dev/null | python3 -c "
import ast, sys
try:
    data = ast.literal_eval(sys.stdin.read())
except Exception:
    sys.exit(0)
for d in data:
    alias = d.get('alias', '')
    addr  = d.get('address', '')
    if alias:
        print(f'{alias}\t{addr}')
"
}

# ===========================================================================
# 手动列表解析
# 一行条目允许三种写法：
#   1) 纯名称：        我的键盘
#   2) 纯 MAC：        AA:BB:CC:DD:EE:FF
#   3) 名称 + MAC：    我的键盘 AA:BB:CC:DD:EE:FF
# ===========================================================================
extract_mac() {
    local line="$1"
    line="$(echo "$line" | xargs)"
    [ -z "$line" ] && return
    if [[ "$line" =~ $MAC_REGEX ]]; then
        echo "$line"; return
    fi
    local last
    last="$(echo "$line" | awk '{print $NF}')"
    if [[ "$last" =~ $MAC_REGEX ]]; then
        echo "$last"; return
    fi
    echo ""
}

extract_name() {
    local line="$1"
    line="$(echo "$line" | xargs)"
    local last
    last="$(echo "$line" | awk '{print $NF}')"
    if [[ "$last" =~ $MAC_REGEX ]]; then
        echo "$line" | sed -E 's/[[:space:]]+([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$//' | xargs
    else
        echo "$line"
    fi
}

# ===========================================================================
# 扫描：收集附近设备的 RSSI（信号强度）与 Alias（名称）
# 全局字典：
#   found_rssi[mac] = -62
#   found_alias[mac] = "我的键盘"
# ===========================================================================
declare -A found_rssi
declare -A found_alias

do_scan() {
    found_rssi=()
    found_alias=()
    local logfile
    logfile="$(mktemp)"

    # 用交互方式跑 bluetoothctl，抓 [CHG] Device MAC RSSI: -xx 这种行
    (
        echo "scan on"
        sleep "$SCAN_SECONDS"
        echo "scan off"
        echo "exit"
    ) | bluetoothctl >"$logfile" 2>&1 || true

    while IFS= read -r ln; do
        if [[ "$ln" =~ Device[[:space:]]+(([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2})[[:space:]]+RSSI[[:space:]]+(-[0-9]+) ]]; then
            found_rssi["${BASH_REMATCH[1]}"]="${BASH_REMATCH[3]}"
        fi
    done < "$logfile"
    rm -f "$logfile"

    # devices 命令输出格式： "Device AA:BB:CC:DD:EE:FF 设备名"
    local dev mac name
    while IFS= read -r dev; do
        mac="$(echo "$dev" | awk '{print $2}')"
        name="$(echo "$dev" | cut -d' ' -f3-)"
        [ -n "$mac" ] && [ "$mac" != "Missing" ] && found_alias["$mac"]="$name"
    done < <(bluetoothctl devices 2>/dev/null)
}

is_connected() {
    local mac="$1"
    bluetoothctl devices Connected 2>/dev/null | grep -qi "$mac"
}

try_connect() {
    local mac="$1"
    echo -e "connect $mac\nexit" | bluetoothctl >/dev/null 2>&1
    sleep 1
    if ! is_connected "$mac"; then
        c_warn "直连失败，尝试 pair + trust：$mac"
        echo -e "pair $mac\ntrust $mac\nconnect $mac\nexit" | bluetoothctl >/dev/null 2>&1
        sleep 1
    fi
}

# ===========================================================================
# run：主连接循环
# ===========================================================================
cmd_run() {
    check_deps
    hciconfig hci0 up >/dev/null 2>&1 || true

    declare -A targets=()     # key=MAC 或 __NAME__::名字，value=展示名
    local src="Blueman RecentConns 缓存"

    # 1) 优先读 Blueman 缓存（自带 MAC，直接连）
    local pairs
    pairs="$(read_blueman_pairs || true)"
    if [ -n "$pairs" ]; then
        local alias addr
        while IFS=$'\t' read -r alias addr; do
            [ -z "$addr" ] && continue
            targets["$addr"]="$alias"
        done <<< "$pairs"
    fi

    # 2) 缓存为空 → 读手动列表
    if [ ${#targets[@]} -eq 0 ]; then
        src="手动列表 $MANUAL_LIST"
        c_warn "Blueman 缓存为空，切换到手动列表"
        [ ! -f "$MANUAL_LIST" ] && { c_err "手动列表文件不存在：$MANUAL_LIST"; exit 1; }
        local line mac name
        while IFS= read -r line; do
            line="$(echo "$line" | xargs)"
            [ -z "$line" ] && continue
            [[ "$line" =~ ^# ]] && continue
            mac="$(extract_mac "$line")"
            name="$(extract_name "$line")"
            if [ -n "$mac" ]; then
                targets["$mac"]="$name"
            else
                # 纯名称条目：扫描时按 alias 匹配
                targets["__NAME__::$name"]="$name"
            fi
        done < "$MANUAL_LIST"
    fi

    if [ ${#targets[@]} -eq 0 ]; then
        c_err "待连接列表为空，退出"
        exit 1
    fi
    c_info "数据源：$src"
    c_info "目标数量：${#targets[@]}"

    local start_ts now elapsed all_ok
    start_ts="$(date +%s)"

    while true; do
        now="$(date +%s)"
        elapsed=$(( now - start_ts ))
        if [ "$elapsed" -ge "$MAX_SECONDS" ]; then
            c_warn "达到 ${MAX_SECONDS}s 超时，退出"
            exit 0
        fi

        do_scan
        all_ok=1

        local mac display
        for mac in "${!targets[@]}"; do
            display="${targets[$mac]}"

            # 纯名称目标：从扫描结果里找 alias 匹配、RSSI 最强的那一个
            if [[ "$mac" == __NAME__::* ]]; then
                local want_name="${mac#__NAME__::}"
                local best_mac="" best_rssi=-999 m r
                for m in "${!found_alias[@]}"; do
                    if [ "${found_alias[$m]}" = "$want_name" ]; then
                        r="${found_rssi[$m]:-999}"
                        if [ "$r" -gt "$best_rssi" ]; then
                            best_rssi="$r"; best_mac="$m"
                        fi
                    fi
                done
                if [ -z "$best_mac" ]; then
                    c_warn "未扫描到名称为 [$want_name] 的设备"
                    all_ok=0
                    continue
                fi
                c_info "[$want_name] 同名择优：$best_mac RSSI=$best_rssi"
                mac="$best_mac"
            fi

            if is_connected "$mac"; then
                c_ok "$display ($mac) 已连接"
                continue
            fi
            all_ok=0

            local rssi="${found_rssi[$mac]:-未知}"
            c_info "尝试连接 $display ($mac) RSSI=$rssi"
            try_connect "$mac"
        done

        if [ "$all_ok" -eq 1 ]; then
            c_ok "全部目标设备连接成功"
            exit 0
        fi
        sleep "$INTERVAL"
    done
}

# ===========================================================================
# cache 子命令：只读 Blueman 缓存，删除会同步反映到托盘菜单
# ===========================================================================
cmd_cache_list() {
    c_info "Blueman RecentConns 原始数据："
    gsettings get "$BLUEMAN_GSET" "$BLUEMAN_KEY" 2>/dev/null || c_warn "读取失败（未安装 Blueman？）"
    echo
    c_info "解析后 (alias / address)："
    read_blueman_pairs | column -t -s $'\t'
}

cmd_cache_del() {
    local alias="$1"
    [ -z "$alias" ] && { c_err "用法: $0 cache-del \"设备别名\""; exit 1; }
    local raw new
    raw="$(gsettings get "$BLUEMAN_GSET" "$BLUEMAN_KEY" 2>/dev/null)"
    new="$(printf '%s' "$raw" | ALIAS="$alias" python3 -c "
import ast, os, sys
data = ast.literal_eval(sys.stdin.read())
out = [x for x in data if x.get('alias') != os.environ['ALIAS']]
print(repr(out))
")"
    gsettings set "$BLUEMAN_GSET" "$BLUEMAN_KEY" "$new"
    c_ok "已从 Blueman 最近连接删除：$alias"
}

# ===========================================================================
# list 子命令：手动维护列表
# ===========================================================================
cmd_list_list() {
    c_info "手动列表：$MANUAL_LIST"
    if [ -f "$MANUAL_LIST" ]; then
        cat "$MANUAL_LIST"
    else
        c_warn "文件不存在（先用 list-add 添加一条）"
    fi
}

cmd_list_add() {
    local entry="$*"
    [ -z "$entry" ] && { c_err "用法: $0 list-add \"条目\""; exit 1; }
    [ -f "$MANUAL_LIST" ] || touch "$MANUAL_LIST"
    echo "$entry" >> "$MANUAL_LIST"
    c_ok "已添加：$entry"
}

cmd_list_del() {
    local entry="$*"
    [ -z "$entry" ] && { c_err "用法: $0 list-del \"条目\""; exit 1; }
    [ -f "$MANUAL_LIST" ] || { c_warn "文件不存在"; exit 1; }
    sed -i "\|^[[:space:]]*$(echo "$entry" | sed 's/[\/&]/\\&/g')[[:space:]]*$|d" "$MANUAL_LIST"
    c_ok "已删除：$entry"
}

# ===========================================================================
# 安装向导：无参数运行时触发
#   - 复制脚本到 /usr/local/bin
#   - 初始化手动列表文件
#   - 生成 systemd 单元并 enable
# ===========================================================================
install_wizard() {
    check_deps
    if is_installed; then
        c_ok "脚本已安装：$SCRIPT_GLOBAL_PATH"
        c_info "全局命令：$SCRIPT_NAME"
        c_info "查看日志：journalctl -u $SERVICE_NAME -f"
        exit 0
    fi

    echo "==== Bluetooth Auto Connect 安装向导 ===="
    echo "目标用户：$CURR_USER (uid=$USER_UID)"

    if [ "$EUID" -ne 0 ]; then
        c_warn "安装需要 root 权限，自动 sudo 重执："
        exec sudo "$0"
    fi

    c_info "1/4 复制脚本到 $SCRIPT_GLOBAL_PATH"
    cp -f "$0" "$SCRIPT_GLOBAL_PATH"
    chmod +x "$SCRIPT_GLOBAL_PATH"

    c_info "2/4 初始化手动列表 $MANUAL_LIST"
    [ -f "$MANUAL_LIST" ] || touch "$MANUAL_LIST"
    chown "$CURR_USER:$CURR_USER" "$MANUAL_LIST" 2>/dev/null || true

    c_info "3/4 生成 systemd 单元 $SERVICE_PATH"
    cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=Bluetooth Auto Connect (Blueman recentconns cache)
After=bluetooth.service
Requires=bluetooth.service

[Service]
Type=oneshot
User=$CURR_USER
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$USER_UID/bus
ExecStart=$SCRIPT_GLOBAL_PATH run
StandardOutput=journal+console

[Install]
WantedBy=multi-user.target
EOF

    c_info "4/4 重载 systemd 并启用开机自启"
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true

    c_ok "安装完成！"
    echo
    echo "常用命令："
    echo "  $SCRIPT_NAME run              # 手动跑一次连接流程"
    echo "  $SCRIPT_NAME cache-list       # 查看 Blueman 最近连接"
    echo "  $SCRIPT_NAME cache-del \"名字\" # 删除缓存项"
    echo "  $SCRIPT_NAME list-list        # 查看手动列表"
    echo "  $SCRIPT_NAME list-add \"名字 AA:BB:CC:DD:EE:FF\""
    echo "  journalctl -u $SERVICE_NAME -f"
}

# ===========================================================================
# 命令入口
# ===========================================================================
case "${1:-}" in
    run)          cmd_run ;;
    cache-list)   cmd_cache_list ;;
    cache-del)    shift; cmd_cache_del "$*" ;;
    list-list)    cmd_list_list ;;
    list-add)    shift; cmd_list_add "$@" ;;
    list-del)     shift; cmd_list_del "$@" ;;
    ""|install)   install_wizard ;;
    *)
        echo "用法："
        echo "  $0                     无参数：进入安装向导"
        echo "  $0 run                 执行自动连接（Blueman 缓存优先，失败回落手动列表）"
        echo "  $0 cache-list          查看 Blueman 最近连接缓存"
        echo "  $0 cache-del \"别名\"    删除 Blueman 缓存项"
        echo "  $0 list-list            查看手动列表"
        echo "  $0 list-add \"条目\"    添加手动条目（名称 / MAC / 名称 MAC）"
        echo "  $0 list-del \"条目\"    删除手动条目"
        exit 1
        ;;
esac
