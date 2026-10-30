#!/usr/bin/env bash
#
# bluetooth-auto-connect.sh
# ---------------------------------------------------------------------------
# 面向 Orange Pi / ARM SBC 的蓝牙键鼠自动连接守护脚本
#
# 两种匹配模式：
#   --name-first（默认）：按设备名称扫描，同名多设备按 RSSI 信号择优
#                         适合外设 MAC 会变化、但名称固定的场景
#   --mac-first：       直接按 MAC 地址连接，跳过名称匹配
#                         适合 MAC 固定、或你想强制直连某个设备的场景
#
# 两个数据来源：
#   1. Blueman「最近连接」缓存（gsettings，重启不丢）
#   2. 手动维护列表 /etc/bt_autoconnect_devices.list（支持 名称 / MAC / 名称+MAC）
#
# 其他特性：
#   - 单次扫描最长 5 分钟，全部连上即提前退出
#   - 无参数运行 = 安装向导（自动装 systemd 开机自启）
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
# gsettings 里 recent-connections 是一个 dict 数组：
#   [{'address': 'AA:BB:..', 'alias': '我的键盘', ...}, ...]
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
#   参数：
#     --name-first   默认。按名称扫描匹配，同名按 RSSI 择优
#     --mac-first    按 MAC 直连，跳过名称匹配
#     --list         强制使用手动列表，不读 Blueman 缓存
# ===========================================================================
cmd_run() {
    check_deps

    local mac_first=0
    local force_list=0
    for arg in "$@"; do
        case "$arg" in
            --mac-first)   mac_first=1 ;;
            --name-first) mac_first=0 ;;
            --list)       force_list=1 ;;
        esac
    done

    hciconfig hci0 up >/dev/null 2>&1 || true

    # 两类目标：
    #   name_targets[]  —— 按名称扫描匹配
    #   mac_targets[]   —— 直连 MAC，元素格式 "MAC|显示名"
    declare -a name_targets=()
    declare -a mac_targets=()
    local src="Blueman RecentConns 缓存"

    # 1) 优先读 Blueman 缓存（除非 --list 强制手动列表）
    if [ "$force_list" -eq 0 ]; then
        local pairs
        pairs="$(read_blueman_pairs || true)"
        if [ -n "$pairs" ]; then
            local alias addr
            while IFS=$'\t' read -r alias addr; do
                [ -z "$alias" ] && continue
                if [ "$mac_first" -eq 1 ] && [ -n "$addr" ]; then
                    # MAC 优先：用缓存里的 address 直连
                    mac_targets+=("${addr}|${alias}")
                else
                    # 名称优先：忽略缓存里的 MAC（可能已过期），只按 alias 扫描
                    name_targets+=("$alias")
                fi
            done <<< "$pairs"
        fi
    fi

    # 2) 缓存为空（或 --list）→ 读手动列表
    if [ ${#name_targets[@]} -eq 0 ] && [ ${#mac_targets[@]} -eq 0 ]; then
        src="手动列表 $MANUAL_LIST"
        c_warn "Blueman 缓存为空（或 --list），切换到手动列表"
        [ ! -f "$MANUAL_LIST" ] && { c_err "手动列表文件不存在：$MANUAL_LIST"; exit 1; }
        local line name mac
        while IFS= read -r line; do
            line="$(echo "$line" | xargs)"
            [ -z "$line" ] && continue
            [[ "$line" =~ ^# ]] && continue
            mac="$(extract_mac "$line")"
            name="$(extract_name "$line")"
            # 纯 MAC 条目时 extract_name 会返回空，这里归一化
            [ "$name" = "$mac" ] && name=""

            if [ "$mac_first" -eq 1 ]; then
                # MAC 优先：有 MAC 就直连，没 MAC 才退化为名称匹配
                if [ -n "$mac" ]; then
                    mac_targets+=("${mac}|${name:-$mac}")
                elif [ -n "$name" ]; then
                    name_targets+=("$name")
                fi
            else
                # 名称优先：有名称就按名称匹配，没名称才退化为直连 MAC
                if [ -n "$name" ]; then
                    name_targets+=("$name")
                elif [ -n "$mac" ]; then
                    mac_targets+=("${mac}|${mac}")
                fi
            fi
        done < "$MANUAL_LIST"
    fi

    if [ ${#name_targets[@]} -eq 0 ] && [ ${#mac_targets[@]} -eq 0 ]; then
        c_err "待连接列表为空，退出"
        exit 1
    fi

    local mode_text
    if [ "$mac_first" -eq 1 ]; then
        mode_text="MAC 优先（直连）"
    else
        mode_text="名称优先（扫描匹配 + RSSI 择优）"
    fi
    c_info "数据源：$src"
    c_info "匹配模式：$mode_text"
    c_info "名称目标：${#name_targets[@]} 个，MAC 目标：${#mac_targets[@]} 个"

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

        # ---- 处理「名称目标」：扫描 → 同名 RSSI 最强 → 连接 ----
        local want_name best_mac best_rssi m r
        for want_name in "${name_targets[@]}"; do
            best_mac="" best_rssi=-999
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
            if is_connected "$best_mac"; then
                c_ok "[$want_name] $best_mac 已连接"
                continue
            fi
            all_ok=0
            c_info "[$want_name] 同名择优：$best_mac RSSI=$best_rssi"
            try_connect "$best_mac"
        done

        # ---- 处理「MAC 目标」：直接 connect（带 pair+trust 兜底）----
        local entry mac display
        for entry in "${mac_targets[@]}"; do
            mac="${entry%%|*}"
            display="${entry#*|}"
            if is_connected "$mac"; then
                c_ok "$display ($mac) 已连接"
                continue
            fi
            all_ok=0
            local rssi="${found_rssi[$mac]:-未知}"
            c_info "直连 $display ($mac) RSSI=$rssi"
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
    # 默认 ExecStart 不带 --mac-first，即默认名称优先
    cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=Bluetooth Auto Connect (name-first, Blueman recentconns cache)
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
    echo "  $SCRIPT_NAME run                  # 默认：名称优先（扫描匹配 + RSSI 择优）"
    echo "  $SCRIPT_NAME run --mac-first       # MAC 优先（直连缓存/列表里的 MAC）"
    echo "  $SCRIPT_NAME run --list           # 强制走手动列表，不读 Blueman 缓存"
    echo "  $SCRIPT_NAME cache-list            # 查看 Blueman 最近连接"
    echo "  $SCRIPT_NAME cache-del \"名字\"      # 删除缓存项"
    echo "  $SCRIPT_NAME list-list            # 查看手动列表"
    echo "  $SCRIPT_NAME list-add \"名字 AA:BB:CC:DD:EE:FF\""
    echo "  journalctl -u $SERVICE_NAME -f"
}

# ===========================================================================
# 命令入口
# ===========================================================================
case "${1:-}" in
    run)          shift; cmd_run "$@" ;;
    cache-list)   cmd_cache_list ;;
    cache-del)    shift; cmd_cache_del "$*" ;;
    list-list)    cmd_list_list ;;
    list-add)    shift; cmd_list_add "$@" ;;
    list-del)     shift; cmd_list_del "$@" ;;
    ""|install)   install_wizard ;;
    *)
        echo "用法："
        echo "  $0                                无参数：进入安装向导"
        echo
        echo "  $0 run [选项]                     执行自动连接"
        echo "    选项："
        echo "      --name-first   （默认）按设备名称扫描匹配，同名按 RSSI 信号择优"
        echo "                     适合外设 MAC 会变化、但名称固定的场景"
        echo "      --mac-first     按 MAC 地址直连，跳过名称匹配"
        echo "                     适合 MAC 固定、或强制直连某个设备"
        echo "      --list          强制使用手动列表，不读 Blueman 托盘缓存"
        echo
        echo "  $0 cache-list                     查看 Blueman 最近连接缓存"
        echo "  $0 cache-del \"别名\"               删除 Blueman 缓存项（托盘菜单同步消失）"
        echo
        echo "  $0 list-list                      查看手动列表"
        echo "  $0 list-add \"条目\"               添加手动条目"
        echo "                     条目格式：名称 / MAC / 名称 MAC"
        echo "  $0 list-del \"条目\"                删除手动条目"
        exit 1
        ;;
esac
